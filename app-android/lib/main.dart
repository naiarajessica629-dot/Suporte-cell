// Cliente de suporte remoto (Android) — captura a tela e transmite para o painel
// do atendente via WebRTC, usando o servidor de sinalização já publicado.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

// Servidor publicado no Render.
const String kHost = 'suporte-cell.onrender.com';

void main() => runApp(const SuporteApp());

class SuporteApp extends StatelessWidget {
  const SuporteApp({super.key});
  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4B93FF);
    return MaterialApp(
      title: 'Suporte Remoto',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F14),
        colorScheme: const ColorScheme.dark(
          primary: accent,
          surface: Color(0xFF141A22),
        ),
      ),
      home: const SharePage(),
    );
  }
}

class SharePage extends StatefulWidget {
  const SharePage({super.key});
  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  final _codeCtrl = TextEditingController();

  RTCPeerConnection? _pc;
  WebSocketChannel? _ws;
  MediaStream? _stream;
  bool _sharing = false;
  bool _connecting = false;
  String _status = '';

  String get _code => _codeCtrl.text.trim().toUpperCase();

  Future<void> _start() async {
    if (_code.isEmpty) {
      _snack('Digite o código do atendimento.');
      return;
    }
    setState(() {
      _connecting = true;
      _status = 'Pedindo permissão para gravar a tela…';
    });

    // Notificações (Android 13+): necessárias para o serviço de captura.
    await Permission.notification.request();

    try {
      _stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {'width': 1280, 'height': 720, 'frameRate': 15},
        'audio': false,
      });
    } catch (e) {
      setState(() {
        _connecting = false;
        _status = 'Você cancelou ou o sistema negou a gravação da tela.';
      });
      return;
    }

    _stream!.getVideoTracks().first.onEnded = () => _stop();
    setState(() => _status = 'Conectando ao atendente…');
    await _connect();
  }

  Future<Map<String, dynamic>> _fetchIce() async {
    try {
      final r = await http.get(Uri.parse('https://$kHost/api/ice'));
      if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {}
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };
  }

  Future<void> _connect() async {
    final ice = await _fetchIce();
    _pc = await createPeerConnection({
      'iceServers': ice['iceServers'],
      'sdpSemantics': 'unified-plan',
    });

    for (final track in _stream!.getTracks()) {
      await _pc!.addTrack(track, _stream!);
    }
    // Prioriza nitidez e limita o bitrate para 4G.
    try {
      final sender = (await _pc!.getSenders()).first;
      final params = sender.parameters;
      params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
      params.encodings = [RTCRtpEncoding(maxBitrate: 1500000, maxFramerate: 15)];
      await sender.setParameters(params);
    } catch (_) {}

    _pc!.onIceCandidate = (c) => _send({'t': 'ice', 'candidate': c.toMap()});
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() {
          _sharing = true;
          _connecting = false;
          _status = 'Sua tela está sendo compartilhada.';
        });
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _pc?.restartIce();
      }
    };

    _ws = WebSocketChannel.connect(Uri.parse('wss://$kHost/signal'));
    _ws!.stream.listen(_onSignal, onError: (_) => _stop(), onDone: () {
      if (_sharing) _stop();
    });
    _send({'t': 'join', 'code': _code, 'role': 'publisher'});

    setState(() {
      _sharing = true;
      _connecting = false;
      _status = 'Conectado. Aguarde o atendente ver sua tela.';
    });
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'error':
        _snack(m['reason']?.toString() ?? 'Erro');
        await _stop();
        break;
      case 'viewer-ready':
        final offer = await _pc!.createOffer();
        await _pc!.setLocalDescription(offer);
        _send({'t': 'offer', 'sdp': offer.sdp});
        break;
      case 'answer':
        await _pc!.setRemoteDescription(
            RTCSessionDescription(m['sdp'] as String, 'answer'));
        break;
      case 'ice':
        final c = m['candidate'] as Map<String, dynamic>;
        await _pc!.addCandidate(RTCIceCandidate(
            c['candidate'] as String?,
            c['sdpMid'] as String?,
            (c['sdpMLineIndex'] as num?)?.toInt()));
        break;
      case 'bye':
        await _stop();
        break;
    }
  }

  Future<void> _stop() async {
    try {
      _send({'t': 'bye'});
    } catch (_) {}
    await _stream?.dispose();
    await _pc?.close();
    await _ws?.sink.close();
    _stream = null;
    _pc = null;
    _ws = null;
    if (mounted) {
      setState(() {
        _sharing = false;
        _connecting = false;
        _status = 'Compartilhamento encerrado.';
      });
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  @override
  void dispose() {
    _stop();
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4B93FF);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.screen_share, color: Colors.white, size: 28),
                  ),
                  const SizedBox(height: 16),
                  const Text('Suporte Remoto',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('Compartilhe sua tela com o atendente',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF97A3B2))),
                  const SizedBox(height: 28),
                  if (!_sharing) ...[
                    TextField(
                      controller: _codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Código do atendimento',
                        hintText: 'Ex.: K7Q2-9XMP',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _connecting ? null : _start,
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16)),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_connecting ? 'Conectando…' : 'Iniciar compartilhamento'),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'O atendente poderá apenas ver sua tela — não controla seu aparelho. Você pode parar quando quiser.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF97A3B2), fontSize: 12.5),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10261B),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(children: [
                        Icon(Icons.fiber_manual_record, color: Color(0xFF35C07E), size: 14),
                        SizedBox(width: 8),
                        Expanded(child: Text('Compartilhando sua tela')),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _stop,
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEC5D5D),
                          padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: const Text('Parar compartilhamento'),
                    ),
                  ],
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(_status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF97A3B2), fontSize: 13)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
