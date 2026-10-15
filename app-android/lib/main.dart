// Cliente de suporte remoto (Android) — aberto pelo LINK do atendente.
// A pessoa toca no link que o atendente enviou; o app abre já pronto e ela
// só confirma o compartilhamento (um toque). Sem código para digitar.
// Somente visualização — ninguém controla o aparelho.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

const String kHost = 'suporte-cell.onrender.com';
const MethodChannel _deeplink = MethodChannel('suporte/deeplink');
const MethodChannel _overlay = MethodChannel('suporte/overlay');

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

enum Step { needLink, ready, sharing }

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

  Step _step = Step.needLink;
  String _code = '';
  String _status = '';
  bool _busy = false;
  bool _overlayOk = true; // controla só a exibição do aviso "permitir guia visual"

  @override
  void initState() {
    super.initState();
    _deeplink.setMethodCallHandler((call) async {
      if (call.method == 'link') _useLink(call.arguments as String?);
    });
    _loadInitialLink();
  }

  Future<void> _loadInitialLink() async {
    try {
      final uri = await _deeplink.invokeMethod<String>('getInitialLink');
      _useLink(uri);
    } catch (_) {}
  }

  void _useLink(String? url) {
    if (url == null) return;
    final code = _codeFromUrl(url);
    if (code != null && mounted) {
      setState(() {
        _code = code;
        _step = Step.ready;
        _status = '';
      });
    }
  }

  String? _codeFromUrl(String url) {
    try {
      final seg = Uri.parse(url).pathSegments;
      final i = seg.indexOf('s');
      if (i >= 0 && i + 1 < seg.length) return seg[i + 1];
    } catch (_) {}
    return null;
  }

  // A pessoa confirma o compartilhamento.
  Future<void> _share() async {
    if (_code.isEmpty) return;
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

    _ws = WebSocketChannel.connect(Uri.parse('wss://$kHost/signal'));
    _ws!.stream.listen(_onSignal, onError: (_) => _stop(), onDone: () { if (_step == Step.sharing) _stop(); });
    _send({'t': 'join', 'code': _code, 'role': 'publisher'});

    try {
      _overlayOk = (await _overlay.invokeMethod<bool>('hasPermission')) ?? false;
    } catch (_) {
      _overlayOk = false;
    }

    setState(() {
      _busy = false;
      _step = Step.sharing;
      _status = 'Aguardando o atendente ver sua tela…';
    });
  }

  Future<Map<String, dynamic>> _fetchIce() async {
    try {
      final r = await http.get(Uri.parse('https://$kHost/api/ice'));
      if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {}
    return {'iceServers': [{'urls': 'stun:stun.l.google.com:19302'}]};
  }

  void _send(Map<String, dynamic> m) => _ws?.sink.add(jsonEncode(m));

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    switch (m['t']) {
      case 'error':
        _showMsg(m['reason']?.toString() ?? 'Erro.');
        await _stop();
        break;
      case 'viewer-ready': // atendente presente: enviar a tela
        final offer = await _pc!.createOffer();
        await _pc!.setLocalDescription(offer);
        _send({'t': 'offer', 'sdp': offer.sdp});
        setState(() => _status = 'Sua tela está sendo compartilhada.');
        break;
      case 'answer':
        await _pc?.setRemoteDescription(RTCSessionDescription(m['sdp'] as String, 'answer'));
        break;
      case 'ice':
        final c = m['candidate'] as Map<String, dynamic>;
        await _pc?.addCandidate(RTCIceCandidate(
            c['candidate'] as String?, c['sdpMid'] as String?, (c['sdpMLineIndex'] as num?)?.toInt()));
        break;
      case 'point': // atendente apontou na tela (guia visual)
        try {
          await _overlay.invokeMethod('show', {'x': m['x'], 'y': m['y']});
        } catch (_) {}
        break;
      case 'clear':
        try { await _overlay.invokeMethod('hide'); } catch (_) {}
        break;
      case 'bye':
        _stop();
        break;
    }
  }

  Future<void> _stop() async {
    try { _send({'t': 'bye'}); } catch (_) {}
    try { await _overlay.invokeMethod('hide'); } catch (_) {}
    await _stream?.dispose();
    await _pc?.close();
    await _ws?.sink.close();
    _stream = null; _pc = null; _ws = null;
    if (mounted) {
      setState(() {
        _step = _code.isNotEmpty ? Step.ready : Step.needLink;
        _status = 'Compartilhamento encerrado.';
      });
    }
  }

  void _showMsg(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
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
                  const SizedBox(height: 28),

                  if (_step == Step.needLink) ...[
                    const Text(
                      'Toque no link que o atendente enviou para começar. Se o app não abriu pelo link, cole o código abaixo.',
                      textAlign: TextAlign.center, style: TextStyle(color: soft, fontSize: 13)),
                    const SizedBox(height: 18),
                    TextField(
                      controller: _codeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Código (se o link não abriu o app)',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _codeCtrl.text.trim().isEmpty
                          ? null
                          : () => setState(() { _code = _codeCtrl.text.trim(); _step = Step.ready; }),
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                      child: const Text('Continuar'),
                    ),
                  ] else if (_step == Step.ready) ...[
                    const Text('O atendente vai ver sua tela para te ajudar. Ninguém controla seu aparelho, e você pode parar quando quiser.',
                        textAlign: TextAlign.center, style: TextStyle(color: soft, fontSize: 13)),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _busy ? null : _share,
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_busy ? 'Aguarde…' : 'Compartilhar minha tela'),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: const Color(0xFF10261B), borderRadius: BorderRadius.circular(10)),
                      child: const Row(children: [
                        Icon(Icons.fiber_manual_record, color: Color(0xFF35C07E), size: 14),
                        SizedBox(width: 8),
                        Expanded(child: Text('Compartilhando sua tela')),
                      ]),
                    ),
                    if (!_overlayOk) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: () async {
                          try { await _overlay.invokeMethod('requestPermission'); } catch (_) {}
                        },
                        icon: const Icon(Icons.touch_app),
                        label: const Text('Permitir o atendente apontar na tela'),
                      ),
                      const Text('Opcional: deixa o atendente mostrar onde tocar.',
                          textAlign: TextAlign.center, style: TextStyle(color: soft, fontSize: 11.5)),
                    ],
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
