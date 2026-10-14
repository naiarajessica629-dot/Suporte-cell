// Cliente de suporte remoto (Android) — consentimento por código.
// A pessoa gera um código no próprio celular e o dita ao atendente.
// O atendente só vê a tela depois de entrar com esse código, e a pessoa
// ainda precisa tocar em "Compartilhar" e aceitar o aviso do sistema.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

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
        colorScheme: const ColorScheme.dark(primary: accent, surface: Color(0xFF141A22)),
      ),
      home: const SharePage(),
    );
  }
}

enum Step { idle, waiting, ready, sharing }

class SharePage extends StatefulWidget {
  const SharePage({super.key});
  @override
  State<SharePage> createState() => _SharePageState();
}

class _SharePageState extends State<SharePage> {
  RTCPeerConnection? _pc;
  WebSocketChannel? _ws;
  MediaStream? _stream;

  Step _step = Step.idle;
  String _code = '';
  String _status = '';
  bool _busy = false;

  String get _host => kHost;

  // 1) A pessoa toca em "Permitir suporte": gera o código e aguarda o atendente.
  Future<void> _permit() async {
    setState(() {
      _busy = true;
      _status = 'Gerando código…';
    });
    String code;
    try {
      final r = await http.post(Uri.parse('https://$_host/api/pair'),
          headers: {'Content-Type': 'application/json'}, body: '{}');
      code = (jsonDecode(r.body) as Map<String, dynamic>)['code'] as String;
    } catch (_) {
      setState(() {
        _busy = false;
        _status = 'Sem conexão com o servidor. Verifique a internet e tente de novo.';
      });
      return;
    }

    _ws = WebSocketChannel.connect(Uri.parse('wss://$_host/signal'));
    _ws!.stream.listen(_onSignal, onError: (_) => _reset('Conexão perdida.'),
        onDone: () { if (_step != Step.idle) _reset('Conexão encerrada.'); });
    _send({'t': 'join', 'code': code, 'role': 'publisher'});

    setState(() {
      _busy = false;
      _code = code;
      _step = Step.waiting;
      _status = 'Passe este código ao atendente e aguarde.';
    });
  }

  // 2) O atendente entrou (viewer-ready). A pessoa decide compartilhar.
  Future<void> _share() async {
    setState(() {
      _busy = true;
      _status = 'Na próxima tela, toque em "Iniciar transmissão".';
    });
    await Permission.notification.request();

    try {
      _stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {'width': 1280, 'height': 720, 'frameRate': 15},
        'audio': false,
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _step = Step.ready;
        _status = 'Você cancelou. Toque de novo para compartilhar.';
      });
      return;
    }
    _stream!.getVideoTracks().first.onEnded = () => _stop();

    final ice = await _fetchIce();
    _pc = await createPeerConnection({'iceServers': ice['iceServers'], 'sdpSemantics': 'unified-plan'});
    for (final t in _stream!.getTracks()) {
      await _pc!.addTrack(t, _stream!);
    }
    _pc!.onIceCandidate = (c) => _send({'t': 'ice', 'candidate': c.toMap()});
    _pc!.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) _pc?.restartIce();
    };

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    _send({'t': 'offer', 'sdp': offer.sdp});

    setState(() {
      _busy = false;
      _step = Step.sharing;
      _status = 'Sua tela está sendo compartilhada.';
    });
  }

  Future<Map<String, dynamic>> _fetchIce() async {
    try {
      final r = await http.get(Uri.parse('https://$_host/api/ice'));
      if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {}
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'}
      ]
    };
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'error':
        _reset(m['reason']?.toString() ?? 'Erro.');
        break;
      case 'viewer-ready': // atendente entrou com o código
        if (_step == Step.waiting) {
          setState(() {
            _step = Step.ready;
            _status = 'Atendente conectado. Toque para compartilhar sua tela.';
          });
        }
        break;
      case 'answer':
        await _pc?.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, 'answer'));
        break;
      case 'ice':
        final c = m['candidate'] as Map<String, dynamic>;
        await _pc?.addCandidate(RTCIceCandidate(
            c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));
        break;
      case 'bye':
        _stop();
        break;
    }
  }

  Future<void> _stop() async {
    try { _send({'t': 'bye'}); } catch (_) {}
    await _stream?.dispose();
    await _pc?.close();
    await _ws?.sink.close();
    _stream = null; _pc = null; _ws = null;
    if (mounted) {
      setState(() {
        _step = Step.idle;
        _code = '';
        _status = 'Compartilhamento encerrado.';
      });
    }
  }

  void _reset(String msg) {
    _stream?.dispose();
    _pc?.close();
    _stream = null; _pc = null; _ws = null;
    if (mounted) {
      setState(() {
        _step = Step.idle;
        _code = '';
        _busy = false;
        _status = msg;
      });
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF4B93FF);
    const soft = Color(0xFF97A3B2);
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
                    width: 56, height: 56,
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.screen_share, color: Colors.white, size: 28),
                  ),
                  const SizedBox(height: 16),
                  const Text('Suporte Remoto',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('Compartilhe sua tela com o atendente',
                      textAlign: TextAlign.center, style: TextStyle(color: soft)),
                  const SizedBox(height: 28),

                  if (_step == Step.idle) ...[
                    FilledButton.icon(
                      onPressed: _busy ? null : _permit,
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      icon: const Icon(Icons.verified_user),
                      label: Text(_busy ? 'Aguarde…' : 'Permitir suporte'),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Ao tocar, aparece um código. Diga esse código ao atendente. Só ele poderá ver sua tela — e somente depois que você tocar em compartilhar. Ninguém controla seu aparelho.',
                      textAlign: TextAlign.center, style: TextStyle(color: soft, fontSize: 12.5)),
                  ] else if (_step == Step.waiting) ...[
                    const Text('Seu código', textAlign: TextAlign.center,
                        style: TextStyle(color: soft, fontSize: 13)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF141A22),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: accent, width: 2),
                      ),
                      child: Text(
                        _code.replaceAllMapped(RegExp(r'.{3}'), (m) => '${m[0]} ').trim(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700, letterSpacing: 6),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Text('Aguardando o atendente entrar…'),
                    ]),
                    const SizedBox(height: 16),
                    TextButton(onPressed: _stop, child: const Text('Cancelar')),
                  ] else if (_step == Step.ready) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10261B), borderRadius: BorderRadius.circular(10)),
                      child: const Row(children: [
                        Icon(Icons.check_circle, color: Color(0xFF35C07E), size: 18),
                        SizedBox(width: 8),
                        Expanded(child: Text('Atendente conectado')),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _share,
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Compartilhar minha tela'),
                    ),
                    const SizedBox(height: 10),
                    TextButton(onPressed: _stop, child: const Text('Cancelar')),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10261B), borderRadius: BorderRadius.circular(10)),
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
                    Text(_status, textAlign: TextAlign.center,
                        style: const TextStyle(color: soft, fontSize: 13)),
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
