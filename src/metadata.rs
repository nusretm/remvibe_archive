//! Stable wire representation of shared FileSystem metadata; no OS operations.
use remvibe_filesystem_core::{
    FileSystemAttributes, FileSystemMetadata, FileSystemPermissions, UnixPermissions,
    WindowsAccessType, WindowsAce, WindowsDacl, WindowsPermissions,
};
use serde::{Deserialize, Serialize};
use std::{fmt, time::{Duration, SystemTime, UNIX_EPOCH}};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MetadataCodecError(pub &'static str);
impl fmt::Display for MetadataCodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(self.0) }
}
impl std::error::Error for MetadataCodecError {}

/// Magnitude from Unix epoch; beforeEpoch is false for zero.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArchiveTimestamp {
    pub before_epoch: bool,
    pub seconds: u64,
    pub nanos: u32,
}
impl ArchiveTimestamp {
    pub fn from_system_time(value: SystemTime) -> Self {
        let (before_epoch, duration) = match value.duration_since(UNIX_EPOCH) {
            Ok(d) => (false, d), Err(e) => (true, e.duration()),
        };
        Self { before_epoch, seconds: duration.as_secs(), nanos: duration.subsec_nanos() }
    }
    pub fn validate(&self) -> Result<(), MetadataCodecError> {
        if self.nanos >= 1_000_000_000 || (self.before_epoch && self.seconds == 0 && self.nanos == 0) {
            return Err(MetadataCodecError("invalid archive timestamp"));
        }
        Ok(())
    }
    pub fn to_system_time(self) -> Result<SystemTime, MetadataCodecError> {
        self.validate()?;
        let d = Duration::new(self.seconds, self.nanos);
        let time = if self.before_epoch { UNIX_EPOCH.checked_sub(d) } else { UNIX_EPOCH.checked_add(d) };
        time.ok_or(MetadataCodecError("timestamp outside native range"))
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArchiveMetadata {
    pub size: Option<u64>,
    pub created_at: Option<ArchiveTimestamp>,
    pub modified_at: Option<ArchiveTimestamp>,
    pub accessed_at: Option<ArchiveTimestamp>,
    pub readonly: Option<bool>,
    pub windows_attributes: Option<u32>,
    permissions: Option<Permissions>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "platform", rename_all = "camelCase", rename_all_fields = "camelCase", deny_unknown_fields)]
enum Permissions {
    Unix { mode: u32, uid: u32, gid: u32 },
    Windows { owner_sid: Option<String>, group_sid: Option<String>, dacl: Dacl, inheritance_enabled: bool },
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum Dacl { Absent, Null, Entries { revision: u8, entries: Vec<Ace> } }
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase", deny_unknown_fields)]
enum Ace { Access { sid: String, access_mask: u32, allow: bool, flags: u8 }, Opaque { bytes: Vec<u8> } }

impl From<&WindowsAce> for Ace {
    fn from(a: &WindowsAce) -> Self {
        match a {
            WindowsAce::Access { sid, access_mask, access_type, flags } =>
                Self::Access { sid: sid.clone(), access_mask: *access_mask, allow: *access_type == WindowsAccessType::Allow, flags: *flags },
            WindowsAce::Opaque(bytes) => Self::Opaque { bytes: bytes.clone() },
        }
    }
}
impl From<&Ace> for WindowsAce {
    fn from(a: &Ace) -> Self {
        match a {
            Ace::Access { sid, access_mask, allow, flags } => Self::Access {
                sid: sid.clone(), access_mask: *access_mask, access_type: if *allow { WindowsAccessType::Allow } else { WindowsAccessType::Deny }, flags: *flags,
            },
            Ace::Opaque { bytes } => Self::Opaque(bytes.clone()),
        }
    }
}
impl From<&FileSystemPermissions> for Permissions {
    fn from(p: &FileSystemPermissions) -> Self {
        match p {
            FileSystemPermissions::Unix(p) => Self::Unix { mode: p.mode, uid: p.uid, gid: p.gid },
            FileSystemPermissions::Windows(p) => Self::Windows {
                owner_sid: p.owner_sid.clone(), group_sid: p.group_sid.clone(), inheritance_enabled: p.inheritance_enabled,
                dacl: match &p.dacl {
                    WindowsDacl::Absent => Dacl::Absent, WindowsDacl::Null => Dacl::Null,
                    WindowsDacl::Entries { revision, entries } => Dacl::Entries { revision: *revision, entries: entries.iter().map(Ace::from).collect() },
                },
            },
        }
    }
}
impl From<&Permissions> for FileSystemPermissions {
    fn from(p: &Permissions) -> Self {
        match p {
            Permissions::Unix { mode, uid, gid } => Self::Unix(UnixPermissions { mode: *mode, uid: *uid, gid: *gid }),
            Permissions::Windows { owner_sid, group_sid, dacl, inheritance_enabled } => Self::Windows(WindowsPermissions {
                owner_sid: owner_sid.clone(), group_sid: group_sid.clone(), inheritance_enabled: *inheritance_enabled,
                dacl: match dacl {
                    Dacl::Absent => WindowsDacl::Absent, Dacl::Null => WindowsDacl::Null,
                    Dacl::Entries { revision, entries } => WindowsDacl::Entries { revision: *revision, entries: entries.iter().map(WindowsAce::from).collect() },
                },
            }),
        }
    }
}

impl From<&FileSystemMetadata> for ArchiveMetadata {
    fn from(m: &FileSystemMetadata) -> Self {
        Self {
            size: m.size, created_at: m.created_at.map(ArchiveTimestamp::from_system_time),
            modified_at: m.modified_at.map(ArchiveTimestamp::from_system_time),
            accessed_at: m.accessed_at.map(ArchiveTimestamp::from_system_time),
            readonly: m.attributes.readonly, windows_attributes: m.attributes.windows,
            permissions: m.permissions.as_ref().map(Permissions::from),
        }
    }
}

impl ArchiveMetadata {
    pub fn validate(&self) -> Result<(), MetadataCodecError> {
        for time in [self.created_at, self.modified_at, self.accessed_at].into_iter().flatten() { time.validate()?; }
        if let Some(Permissions::Unix { mode, .. }) = &self.permissions {
            if mode & !0o7777 != 0 { return Err(MetadataCodecError("invalid Unix permission bits")); }
        }
        Ok(())
    }
    pub fn to_filesystem(&self) -> Result<FileSystemMetadata, MetadataCodecError> {
        self.validate()?;
        Ok(FileSystemMetadata {
            size: self.size,
            created_at: self.created_at.map(ArchiveTimestamp::to_system_time).transpose()?,
            modified_at: self.modified_at.map(ArchiveTimestamp::to_system_time).transpose()?,
            accessed_at: self.accessed_at.map(ArchiveTimestamp::to_system_time).transpose()?,
            permissions: self.permissions.as_ref().map(FileSystemPermissions::from),
            attributes: FileSystemAttributes { readonly: self.readonly, windows: self.windows_attributes },
        })
    }
}
