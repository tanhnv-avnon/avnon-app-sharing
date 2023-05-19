import 'dart:async';

import 'package:injectable/injectable.dart';
import 'package:signalr_core/signalr_core.dart';

import '../../core/constants/duration_constants.dart';
import '../../core/mixins/mixins.dart';
import '../datasources/gateway/api/clients/socket/signalr_client.dart';
import '../models/socket/socket.dart';

@lazySingleton
class AppSocketProvider with LogMixin {
  AppSocketProvider(this._signalRClient);

  final SignalRClient _signalRClient;

  late HubConnection _connection;

  final StreamController<ChannelEvent> _messageIncomingStream = StreamController.broadcast();
  Timer? _reJoinTimer;
  Completer<void>? _establishConnectionCompleter;

  final _channelsMap = <String, List<JoinedChannelData>>{};

  Stream<ChannelEvent> get messageIncomingStream => _messageIncomingStream.stream.distinct();

  Future<void> establishConnection() async {
    _establishConnectionCompleter = Completer();
    _connection = await _signalRClient.getConnection();
    _establishConnectionCompleter!.complete();
    await joinChannel('dashboard');

    _connection.onclose((exception) {
      _messageIncomingStream.close();
    });

    _listenEvents();
  }

  void _listenEvents() {
    _connection.on('transferMessageIncoming', (arguments) {
      try {
        if (arguments == null) {
          return;
        }

        final chanelArgument = ChannelArgument.fromArgument(arguments);

        _messageIncomingStream.add(chanelArgument.data);
      } catch (e) {
        logError('Failed to listen transferMessageIncoming events', e);
      }
    });
  }

  Future<void> closeConnection() async {
    if (_signalRClient.isConnected) {
      _clearTimer();
      _closeAllStreams();

      return _connection.stop();
    }
  }

  void _clearTimer() {
    _reJoinTimer?.cancel();
  }

  void _closeAllStreams() {
    _messageIncomingStream.close();
  }

  Future<dynamic> _invoke(String methodName, dynamic args) async {
    if (_establishConnectionCompleter != null && !_establishConnectionCompleter!.isCompleted) {
      await _establishConnectionCompleter!.future;
    }

    try {
      return await _connection.invoke(methodName, args: <dynamic>[args]);
    } catch (e) {
      rethrow;
    }
  }

  List<String> _getConnectionIds(String channel) {
    return _channelsMap[channel]!.map((e) => e.connectionId).toList();
  }

  Future<void> joinChannel(String channel) async {
    try {
      _reJoinTimer?.cancel();

      final List<dynamic> signal = await _invoke('joinChannel', channel);
      logInfo('Joined channel: $channel - $signal');

      final joinedChannelDataList = signal.map((dynamic e) => JoinedChannelData.fromJson(e)).toList();
      _setChannelMap(channel, joinedChannelDataList);
    } catch (e) {
      _reJoinTimer = Timer(
        ApiDurationConstants.reJoinChannelDuration,
        () => joinChannel(channel),
      );
    }
  }

  void _setChannelMap(String channel, List<JoinedChannelData> joinedChannelDataList) {
    _channelsMap[channel] = joinedChannelDataList;
  }

  Future<void> leaveChannel(String channel) async {
    try {
      final List<dynamic> onlineClients = await _invoke('leaveChannel', [channel, null]);

      final joinedChannelDataList = onlineClients.map((dynamic e) => JoinedChannelData.fromJson(e)).toList();
      _setChannelMap(channel, joinedChannelDataList);
      logInfo('Left channel: $onlineClients');
    } catch (e) {
      logError('Failed to leave channel', e);
    }
  }

  void transferMessage(String channel, dynamic data) {
    try {
      final connections = _getConnectionIds(channel);
      _invoke('transferMessage', <dynamic>[channel, data, connections]);
    } catch (e) {
      logError('Failed to transfer message', e);
    }
  }
}
