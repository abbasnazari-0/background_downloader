import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

import 'downloader.dart';
import 'models.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

/// True if this platform is supported by the DesktopDownloader
final desktopDownloaderSupportsThisPlatform =
    Platform.isMacOS || Platform.isLinux || Platform.isWindows;

const okResponses = [200, 201, 202, 203, 204, 205, 206];

/// Implementation of the core download functionality for desktop platforms
///
/// On desktop (MacOS, Linux, Windows) the download and upload are implemented
/// in Dart, as there is no native platform equivalent of URLSession or
/// WorkManager as there is on iOS and Android
class DesktopDownloader {
  final log = Logger('FileDownloader');
  final maxConcurrent = 5;
  static final DesktopDownloader _singleton = DesktopDownloader._internal();
  final _queue = Queue<Task>();
  final _running = Queue<Task>(); // subset that is running
  final _isolateSendPorts =
      <Task, SendPort?>{}; // isolate SendPort for running task
  var _updatesStreamController = StreamController();
  static final httpClient = http.Client();

  factory DesktopDownloader() {
    return _singleton;
  }

  /// Private constructor for singleton
  DesktopDownloader._internal();

  Stream get updates => _updatesStreamController.stream;

  /// Initialize the [DesktopDownloader]
  ///
  /// Call before listening to the updates stream
  void initialize() => _updatesStreamController = StreamController();

  /// Enqueue the task and advance the queue
  bool enqueue(Task task) {
    _queue.add(task);
    _emitUpdate(task, TaskStatus.enqueued);
    _advanceQueue();
    return true;
  }

  /// Advance the queue if it's not empty and there is room in the run queue
  void _advanceQueue() {
    while (_running.length < maxConcurrent && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _running.add(task);
      _executeTask(task).then((_) {
        _running.remove(task);
        _advanceQueue();
      });
    }
  }

  /// Execute this task
  ///
  /// The task runs on an Isolate, which is sent the task information and
  /// which will emit status and progress updates.  These updates will be
  /// 'forwarded' to the [backgroundChannel] and processed by the
  /// [FileDownloader]
  Future<void> _executeTask(Task task) async {
    final Directory baseDir;
    switch (task.baseDirectory) {
      case BaseDirectory.applicationDocuments:
        baseDir = await getApplicationDocumentsDirectory();
        break;
      case BaseDirectory.temporary:
        baseDir = await getTemporaryDirectory();
        break;
      case BaseDirectory.applicationSupport:
        baseDir = await getApplicationSupportDirectory();
        break;
    }
    final filePath = path.join(baseDir.path, task.directory, task.filename);
    // spawn an isolate to do the task
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    errorPort.listen((message) {
      final error = (message as List).first as String;
      log.info('Error for taskId ${task.taskId}: $error');
      _emitUpdate(task, TaskStatus.failed);
      receivePort.close(); // also ends listener at then end
    });
    await Isolate.spawn(doTask, receivePort.sendPort,
        onError: errorPort.sendPort);
    // Convert the ReceivePort into a StreamQueue to receive messages from the
    // spawned isolate using a pull-based interface. Events are stored in this
    // queue until they are accessed by `events.next`.
    final messagesFromIsolate = StreamQueue<dynamic>(receivePort);
    // The first message from the spawned isolate is a SendPort. This port is
    // used to communicate with the spawned isolate.
    final sendPort = await messagesFromIsolate.next;
    sendPort.send([task, filePath]);
    if (_isolateSendPorts.keys.contains(task)) {
      // if already registered with null value, cancel immediately
      sendPort.send('cancel');
    }
    _isolateSendPorts[task] = sendPort; // allows future cancellation
    // listen for events sent back from the isolate
    while (await messagesFromIsolate.hasNext) {
      final message = await messagesFromIsolate.next;
      if (message == null) {
        // sent when final state has been sent
        receivePort.close();
      } else {
        // Pass message on to FileDownloader via [updates]
        _emitUpdate(task, message);
      }
    }
    errorPort.close();
    _isolateSendPorts.remove(task);
  }

  /// Resets the download worker by cancelling all ongoing tasks for the group
  ///
  ///  Returns the number of tasks canceled
  int reset(String group) {
    final inQueueIds =
        _queue.where((task) => task.group == group).map((task) => task.taskId);
    final runningIds = _running
        .where((task) => task.group == group)
        .map((task) => task.taskId);
    final taskIds = [...inQueueIds, ...runningIds];
    if (taskIds.isNotEmpty) {
      cancelTasksWithIds(taskIds);
    }
    return taskIds.length;
  }

  /// Returns a list of all tasks in progress, matching [group]
  List<Task> allTasks(String group) {
    final inQueue = _queue.where((task) => task.group == group);
    final running = _running.where((task) => task.group == group);
    return [...inQueue, ...running];
  }

  /// Cancels ongoing tasks whose taskId is in the list provided with this call
  ///
  /// Returns true if all cancellations were successful
  bool cancelTasksWithIds(List<String> taskIds) {
    final inQueue = _queue.where((task) => taskIds.contains(task.taskId));
    for (final task in inQueue) {
      _emitUpdate(task, TaskStatus.canceled);
      _remove(task);
    }
    final running = _running.where((task) => taskIds.contains(task.taskId));
    for (final task in running) {
      final sendPort = _isolateSendPorts[task];
      if (sendPort != null) {
        sendPort.send('cancel');
        _isolateSendPorts.remove(task);
      } else {
        // register task for cancellation even if sendPort does not yet exist
        _isolateSendPorts[task] = null;
      }
    }
    return true;
  }

  /// Returns Task for this taskId, or nil
  Task? taskForId(String taskId) {
    try {
      return _queue.where((task) => task.taskId == taskId).first;
    } on StateError {
      try {
        return _running.where((task) => task.taskId == taskId).first;
      } on StateError {
        return null;
      }
    }
  }

  /// Destroy requiring re-initialization
  ///
  /// Clears all queues and references without sending cancellation
  /// messages or status updates
  void destroy() {
    _queue.clear();
    _running.clear();
    _isolateSendPorts.clear();
  }

  /// Emit status or progress update to [FileDownloader] if task provides those
  void _emitUpdate(Task task, dynamic message) {
    if ((message is TaskStatus && task.providesStatusUpdates) ||
        (message is double && task.providesProgressUpdates)) {
      _updatesStreamController.add([task, message]);
    }
  }

  /// Remove all references to [task]
  void _remove(Task task) {
    _queue.remove(task);
    _running.remove(task);
    _isolateSendPorts.remove(task);
  }
}

/** Top-level functions that run in an Isolate */

/// Do the task, sending messages back to the main isolate via [sendPort]
///
/// The first message sent back is a [ReceivePort] that is the command port
/// for the isolate. The first command must be the arguments: task and filePath.
/// Any subsequent commands will be interpreted as a cancellation request.
Future<void> doTask(SendPort sendPort) async {
  final commandPort = ReceivePort();
  // send the command port back to the main Isolate
  sendPort.send(commandPort.sendPort);
  final messagesToIsolate = StreamQueue<dynamic>(commandPort);
  // get the arguments list and parse
  final args = await messagesToIsolate.next as List<dynamic>;
  final task = args.first;
  final filePath = args.last as String;
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((LogRecord rec) {
    if (kDebugMode) {
      print('${rec.loggerName}>${rec.level.name}: ${rec.time}: ${rec.message}');
    }
  });
  FileDownloader.httpClient ??= http.Client();
  processStatusUpdate(task, TaskStatus.running, sendPort);
  processProgressUpdate(task, 0.0, sendPort);
  if (task.retriesRemaining < 0) {
    Logger('FileDownloader').warning(
        'Task with taskId ${task.taskId} has negative retries remaining');
    processStatusUpdate(task, TaskStatus.failed, sendPort);
  } else {
    if (task is DownloadTask) {
      await doDownloadTask(task, filePath, sendPort, messagesToIsolate);
    } else {
      await doUploadTask(task, filePath, sendPort, messagesToIsolate);
    }
  }
  sendPort.send(null); // signals end
  Isolate.exit();
}

Future<void> doDownloadTask(Task task, String filePath, SendPort sendPort,
    StreamQueue messagesToIsolate) async {
  final log = Logger('FileDownloader');
  final client = DesktopDownloader.httpClient;
  final tempFileName = Random().nextInt(1 << 32).toString();
  var request = task.post == null
      ? http.Request('GET', Uri.parse(task.url))
      : http.Request('POST', Uri.parse(task.url));
  request.headers.addAll(task.headers);
  if (task.post is String) {
    request.body = task.post!;
  }
  var resultStatus = TaskStatus.failed;
  try {
    final response = await client.send(request);
    final contentLength = response.contentLength ?? -1;
    if (okResponses.contains(response.statusCode)) {
      IOSink? outStream;
      try {
        // do the actual download
        outStream = File(tempFileName).openWrite();
        final transferBytesResult = await transferBytes(response.stream, outStream,
            contentLength, task, sendPort, messagesToIsolate);
        if (transferBytesResult == TaskStatus.complete) {
          // copy file to destination, creating dirs if needed
          final dirPath = path.dirname(filePath);
          Directory(dirPath).createSync(recursive: true);
          await File(tempFileName).copy(filePath);
        }
        if ([TaskStatus.complete, TaskStatus.canceled].contains(transferBytesResult)) {
          resultStatus = transferBytesResult;
        }
      } on FileSystemException catch (e) {
        log.warning(e);
      } finally {
        try {
          outStream?.close();
          File(tempFileName).deleteSync();
        } catch (e) {}
      }
    } else {
      // not an OK response
      if (response.statusCode == 404) {
        resultStatus = TaskStatus.notFound;
      }
    }
  } catch (e) {
    log.warning(e);
  }
  processStatusUpdate(task, resultStatus, sendPort);
}

Future<void> doUploadTask(Task task, String filePath, SendPort sendPort,
    StreamQueue messagesToIsolate) async {
  final log = Logger('FileDownloader');
  final inFile = File(filePath);
  if (!inFile.existsSync()) {
    log.warning(
        'TaskId ${task.taskId} file to upload does not exist: $filePath');
    processStatusUpdate(task, TaskStatus.failed, sendPort);
    return;
  }
  final isBinaryUpload = task.post == 'binary';
  final fileSize = inFile.lengthSync();
  final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
  const boundary = '-----background_downloader-akjhfw281onqciyhnIk';
  const lineFeed = '\r\n';
  final contentDispositionString =
      'Content-Disposition: form-data; name="file"; filename="${task.filename}"';
  final contentTypeString = 'Content-Type: $mimeType';
  // determine the content length of the multi-part data
  final contentLength = isBinaryUpload
      ? fileSize
      : 2 * boundary.length +
          6 * lineFeed.length +
          contentDispositionString.length +
          contentTypeString.length +
          3 * "--".length +
          fileSize;
  try {
    final client = DesktopDownloader.httpClient;
    final request = http.StreamedRequest('POST', Uri.parse(task.url));
    request.headers.addAll(task.headers);
    request.contentLength = contentLength;
    if (isBinaryUpload) {
      request.headers['Content-Type'] = mimeType;
    } else {
      // multi-part upload
      request.headers.addAll({
        'Content-Type': 'multipart/form-data; boundary=$boundary',
        'Accept-Charset': 'UTF-8',
        'Connection': 'Keep-Alive',
        'Cache-Control': 'no-cache'
      });
      // write pre-amble
      request.sink.add(utf8.encode(
          '--$boundary$lineFeed$contentDispositionString$lineFeed$contentTypeString$lineFeed$lineFeed'));
    }
    // initiate the request and handle completion async
    final requestCompleter = Completer();
    var result = TaskStatus.failed; // additionally set below .then statement
    client.send(request).then((response) {
      // request completed, so send status update and finish
      var resultToSend = result == TaskStatus.complete &&
              !okResponses.contains(response.statusCode)
          ? TaskStatus.failed
          : result;
      if (response.statusCode == 404) {
        resultToSend = TaskStatus.notFound;
      }
      processStatusUpdate(task, resultToSend, sendPort);
      requestCompleter.complete();
    });
    // send the bytes to the request sink
    final inStream = inFile.openRead();
    result = await transferBytes(inStream, request.sink, contentLength, task,
        sendPort, messagesToIsolate);
    if (!isBinaryUpload && result == TaskStatus.complete) {
      // write epilogue
      request.sink.add(utf8.encode('$lineFeed--$boundary--$lineFeed'));
    }
    request.sink.close(); // triggers request completion, handled above
    await requestCompleter.future; // wait for request to complete
  } catch (e) {
    processStatusUpdate(task, TaskStatus.failed, sendPort);
  }
}

Future<TaskStatus> transferBytes(
    Stream<List<int>> inStream,
    EventSink<List<int>> outStream,
    int contentLength,
    Task task,
    SendPort sendPort,
    StreamQueue messagesToIsolate) async {
  final log = Logger('FileDownloader');
  if (contentLength == 0) {
    contentLength = -1;
  }
  var isCanceled = false;
  messagesToIsolate.next.then((message) {
    assert(message == 'cancel', 'Only accept "cancel" messages');
    isCanceled = true;
  });
  final streamResultStatus = Completer<TaskStatus>();
  var bytesTotal = 0;
  var lastProgressUpdate = 0.0;
  var nextProgressUpdateTime = DateTime.fromMillisecondsSinceEpoch(0);
  late StreamSubscription<List<int>> subscription;
  subscription = inStream.listen(
      (bytes) async {
        if (isCanceled) {
          streamResultStatus.complete(TaskStatus.canceled);
          return;
        }
        outStream.add(bytes);
        bytesTotal += bytes.length;
        final progress = min(bytesTotal.toDouble() / contentLength, 0.999);
        final now = DateTime.now();
        if (contentLength > 0 &&
            (bytesTotal < 10000 ||
                (progress - lastProgressUpdate > 0.02 &&
                    now.isAfter(nextProgressUpdateTime)))) {
          processProgressUpdate(task, progress, sendPort);
          lastProgressUpdate = progress;
          nextProgressUpdateTime = now.add(const Duration(milliseconds: 500));
        }
      },
      onDone: () => streamResultStatus.complete(TaskStatus.complete),
      onError: (e) {
        log.warning('Error downloading taskId ${task.taskId}: $e');
        streamResultStatus.complete(TaskStatus.failed);
      });
  final resultStatus = await streamResultStatus.future;
  await subscription.cancel();
  return resultStatus;
}

/// Processes a change in status for the [task]
///
/// Sends status update via the [sendPort], if requested
/// If the task is finished, processes a final progressUpdate update
void processStatusUpdate(Task task, TaskStatus status, SendPort sendPort) {
  final retryNeeded = status == TaskStatus.failed && task.retriesRemaining > 0;
// if task is in final state, process a final progressUpdate
// A 'failed' progress update is only provided if
// a retry is not needed: if it is needed, a `waitingToRetry` progress update
// will be generated in the FileDownloader
  if (status.isFinalState) {
    switch (status) {
      case TaskStatus.complete:
        {
          processProgressUpdate(task, progressComplete, sendPort);
          break;
        }
      case TaskStatus.failed:
        {
          if (!retryNeeded) {
            processProgressUpdate(task, progressFailed, sendPort);
          }
          break;
        }
      case TaskStatus.canceled:
        {
          processProgressUpdate(task, progressCanceled, sendPort);
          break;
        }
      case TaskStatus.notFound:
        {
          processProgressUpdate(task, progressNotFound, sendPort);
          break;
        }
      default:
        {}
    }
  }
// Post update if task expects one, or if failed and retry is needed
  if (task.providesStatusUpdates || retryNeeded) {
    sendPort.send(status);
  }
}

/// Processes a progress update for the [task]
///
/// Sends progress update via the [sendPort], if requested
void processProgressUpdate(Task task, double progress, SendPort sendPort) {
  if (task.providesProgressUpdates) {
    sendPort.send(progress);
  }
}