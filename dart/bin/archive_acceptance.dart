// Focused E acceptance entrypoint. All archive work uses the public Dart API.
// Keep the existing A-D probes callable without duplicating them.
import '../example/foundation.dart' as foundation;
import '../example/writer.dart' as writer;
import '../example/reader.dart' as reader;
import '../example/streaming.dart' as streaming;
import '../example/exchange.dart' as exchange;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError('Usage: archive_acceptance '
        'foundation [library] | writer/reader/streaming <work> [library] | '
        'produce <empty-exchange-directory> [library] | '
        'consume <archive-directory> <origin-os> <empty-output-directory> [library]');
  }
  final rest = args.sublist(1);
  switch (args.first) {
    case 'foundation':
      await foundation.main(rest);
      break;
    case 'writer':
      await writer.main(rest);
      break;
    case 'reader':
      await reader.main(rest);
      break;
    case 'streaming':
      await streaming.main(rest);
      break;
    case 'produce':
    case 'consume':
      await exchange.main(args);
      break;
    default:
      throw ArgumentError('Unknown acceptance command: ${args.first}');
  }
}
