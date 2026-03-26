import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Full-screen WebView that loads the CHO patient dashboard:
///   https://dhanvantari.net.in/cho_module/dashboard/{patientId}?access_token=…
///
/// This gives the CHO the complete "Find Doctor" + "Consult Now" interface
/// for a specific patient — the same page as the web portal.
class PatientConsultationPage extends StatefulWidget {
  final String patientId;
  final String patientName;

  const PatientConsultationPage({
    super.key,
    required this.patientId,
    required this.patientName,
  });

  @override
  State<PatientConsultationPage> createState() =>
      _PatientConsultationPageState();
}

class _PatientConsultationPageState extends State<PatientConsultationPage> {
  WebViewController? _controller;
  String? _authToken;
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    // Camera / mic needed if the CHO starts a video consultation from here.
    _initPage();
  }

  Future<void> _initPage() async {
    await [Permission.camera, Permission.microphone].request();

    final prefs = await SharedPreferences.getInstance();
    _authToken = prefs.getString('auth_token');
    final cookies = prefs.getString('cookies') ?? '';

    if (cookies.isNotEmpty) await _injectCookies(cookies);
    if (mounted) _initWebView();
  }

  Future<void> _injectCookies(String cookieHeader) async {
    const skipCookies = {'csrftoken', 'csrfmiddlewaretoken'};
    final cookieManager = WebViewCookieManager();
    for (final pair in cookieHeader.split(';')) {
      final kv = pair.trim().split('=');
      if (kv.length < 2) continue;
      final rawName = kv[0].trim();
      final name = rawName.toLowerCase();
      final value = kv.sublist(1).join('=').trim();
      if (rawName.isEmpty || value.isEmpty || skipCookies.contains(name)) {
        continue;
      }
      try {
        await cookieManager.setCookie(WebViewCookie(
          name: rawName,
          value: value,
          domain: 'dhanvantari.net.in',
          path: '/',
        ));
      } catch (_) {}
    }
  }

  void _initWebView() {
    final token = _authToken ?? '';
    final url = Uri.https(
      'dhanvantari.net.in',
      '/cho_module/dashboard/${widget.patientId}',
      token.isNotEmpty ? {'access_token': token} : null,
    ).toString();

    debugPrint('🩺 PatientConsultation: loading $url');

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) {
          final uri = Uri.tryParse(req.url);
          if (uri != null) {
            final path = uri.path.toLowerCase();
            // If the web portal redirects to login, close this page.
            if (path.contains('/login') || path.contains('/signin')) {
              debugPrint('🩺 PatientConsultation: redirect to login → popping');
              if (mounted) Navigator.pop(context);
              return NavigationDecision.prevent;
            }
          }
          return NavigationDecision.navigate;
        },
        onPageStarted: (_) {
          if (mounted) setState(() => _isLoading = true);
          _injectAuth(isEarly: true);
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _isLoading = false);
          _injectAuth();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) {
            debugPrint('❌ PatientConsultation error: ${e.description}');
            if (mounted) {
              setState(() {
                _isLoading = false;
                _hasError = true;
                _errorMsg = e.description;
              });
            }
          }
        },
      ))
      ..loadRequest(Uri.parse(url));

    final platform = _controller!.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
      platform.setOnPlatformPermissionRequest((req) => req.grant());
    }

    if (mounted) setState(() {});
  }

  /// Inject JWT Bearer token + CSRF into all XHR / fetch calls.
  void _injectAuth({bool isEarly = false}) {
    if (_controller == null) return;
    final token = _authToken ?? '';
    final safeToken = token
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '')
        .replaceAll('\r', '');
    final phase = isEarly ? 'early' : 'late';

    _controller!.runJavaScript("""
(function(){
  var token = '$safeToken';
  function getCsrf(){
    try{var m=document.cookie.match(/(?:^|;\\s*)csrftoken=([^;]+)/);return m?decodeURIComponent(m[1]):''}catch(e){return ''}
  }
  if(token){
    try{
      localStorage.setItem('token',token);
      localStorage.setItem('auth_token',token);
      localStorage.setItem('access_token',token);
      localStorage.setItem('authToken',token);
    }catch(e){}
  }
  if(!window.__choFetchPatched){
    window.__choFetchPatched=true;
    var _f=window.fetch.bind(window);
    window.fetch=function(i,o){o=o||{};try{var h=new Headers(o.headers||{});if(token&&!h.has('Authorization'))h.set('Authorization','Bearer '+token);var c=getCsrf();if(c&&!h.has('X-CSRFToken'))h.set('X-CSRFToken',c);o.headers=h}catch(e){}return _f(i,o)};
  }
  if(!window.__choXhrPatched){
    window.__choXhrPatched=true;
    var _o=XMLHttpRequest.prototype.open,_s=XMLHttpRequest.prototype.send,_r=XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.open=function(){this.__ai=false;return _o.apply(this,arguments)};
    XMLHttpRequest.prototype.send=function(){if(!this.__ai){this.__ai=true;try{if(token)_r.call(this,'Authorization','Bearer '+token);var c=getCsrf();if(c)_r.call(this,'X-CSRFToken',c)}catch(e){}}return _s.apply(this,arguments)};
  }
  console.log('✅ CHO consult auth [$phase]: token='+(token?token.length+'ch':'EMPTY'));
})();
""").catchError((_) {});
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          leading: IconButton(
            onPressed: _handleBack,
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            color: const Color(0xFF0E7C7B),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.patientName,
                style: GoogleFonts.poppins(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF0E7C7B),
                ),
              ),
              Text(
                'Consultation',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: Colors.grey[500],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: () {
                setState(() {
                  _hasError = false;
                  _isLoading = true;
                });
                _controller?.reload();
              },
              icon: const Icon(Icons.refresh_rounded, size: 20),
              color: Colors.grey[600],
              tooltip: 'Reload',
            ),
          ],
          bottom: _isLoading
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.grey[200],
                    color: const Color(0xFF0E7C7B),
                    minHeight: 2,
                  ),
                )
              : null,
        ),
        body: Stack(
          children: [
            if (_controller != null && !_hasError)
              WebViewWidget(controller: _controller!),

            if (_hasError)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off_rounded,
                          size: 56, color: Colors.grey),
                      const SizedBox(height: 16),
                      Text(
                        'Could not load patient dashboard',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMsg.isNotEmpty
                            ? _errorMsg
                            : 'Check your internet connection and try again.',
                        style: GoogleFonts.inter(
                            fontSize: 13, color: Colors.grey[600]),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _hasError = false;
                            _isLoading = true;
                          });
                          _controller?.reload();
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text('Retry',
                            style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0E7C7B),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _handleBack() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Leave Consultation?',
            style: GoogleFonts.poppins(
                fontSize: 15, fontWeight: FontWeight.w600)),
        content: Text(
          'Are you sure you want to go back to the dashboard?',
          style: GoogleFonts.inter(fontSize: 13, color: Colors.grey[600]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Stay',
                style: GoogleFonts.inter(
                    fontSize: 13, color: const Color(0xFF0E7C7B))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0E7C7B),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Leave',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
