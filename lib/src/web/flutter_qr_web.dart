// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:core';
// import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:ui' as ui;
import 'package:web/web.dart' as web;

import 'package:flutter/material.dart';

import '../../qr_code_scanner_plus.dart';
import 'jsqr.dart';
import 'media.dart';

/// Even though it has been highly modified, the origial implementation has been
/// adopted from https://github.com:treeder/jsqr_flutter
///
/// Copyright 2020 @treeder
/// Copyright 2021 The one with the braid

class WebQrView extends StatefulWidget {
  final QRViewCreatedCallback onPlatformViewCreated;
  final PermissionSetCallback? onPermissionSet;
  final CameraFacing? cameraFacing;

  const WebQrView({
    super.key,
    required this.onPlatformViewCreated,
    this.onPermissionSet,
    this.cameraFacing = CameraFacing.front,
  });

  @override
  State<StatefulWidget> createState() => _WebQrViewState();

  static web.HTMLDivElement vidDiv =
      web.HTMLDivElement(); // need a global for the registerViewFactory

  static Future<bool> cameraAvailable() async {
    final sources =
        await web.window.navigator.mediaDevices.enumerateDevices().toDart;
    // List<String> vidIds = [];
    var hasCam = false;
    for (final e in sources.toDart) {
      if (e.kind == 'videoinput') {
        // vidIds.add(e['deviceId']);
        hasCam = true;
      }
    }
    return hasCam;
  }
}

class _WebQrViewState extends State<WebQrView> {
  web.MediaStream? _localStream;
  // html.CanvasElement canvas;
  // html.CanvasRenderingContext2D ctx;
  bool _currentlyProcessing = false;

  QRViewControllerWeb? _controller;

  late Size _size = const Size(0, 0);
  Timer? timer;
  String? code;
  String? _errorMsg;
  web.HTMLVideoElement video = web.HTMLVideoElement();
  String viewID = 'QRVIEW-${DateTime.now().millisecondsSinceEpoch}';

  final StreamController<Barcode> _scanUpdateController =
      StreamController<Barcode>();
  late CameraFacing facing;

  Timer? _frameIntervall;

  @override
  void initState() {
    super.initState();

    facing = widget.cameraFacing ?? CameraFacing.front;

    // TODO: old dart:html implementation was doing this which is not possible with web package
    // WebQrView.vidDiv.children = [video];
    WebQrView.vidDiv.children.add(video);

    // ignore: UNDEFINED_PREFIXED_NAME
    ui.platformViewRegistry
        .registerViewFactory(viewID, (int id) => WebQrView.vidDiv);
    // giving JavaScipt some time to process the DOM changes
    Timer(const Duration(milliseconds: 500), () {
      start();
    });
  }

  Future start() async {
    await _makeCall();
    _frameIntervall?.cancel();
    _frameIntervall =
        Timer.periodic(const Duration(milliseconds: 200), (timer) {
      _captureFrame2();
    });
  }

  void cancel() {
    if (timer != null) {
      timer!.cancel();
      timer = null;
    }
    if (_currentlyProcessing) {
      _stopStream();
    }
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> _makeCall() async {
    if (_localStream != null) {
      return;
    }

    try {
      var constraints = UserMediaOptions(
          video: VideoOptions(
        facingMode: (facing == CameraFacing.front ? 'user' : 'environment'),
      ));
      // dart style, not working properly:
      // var stream =
      //     await html.window.navigator.mediaDevices.getUserMedia(constraints);
      // straight JS:
      if (_controller == null) {
        _controller = QRViewControllerWeb(this);
        widget.onPlatformViewCreated(_controller!);
      }
      var stream = await getUserMedia(constraints).toDart;
      widget.onPermissionSet?.call(_controller!, true);
      _localStream = stream;
      video.srcObject = _localStream;
      video.setAttribute('playsinline',
          'true'); // required to tell iOS safari we don't want fullscreen
      await video.play().toDart;
    } catch (e) {
      cancel();
      if (e.toString().contains("NotAllowedError")) {
        widget.onPermissionSet?.call(_controller!, false);
      }
      setState(() {
        _errorMsg = e.toString();
      });
      return;
    }
    if (!mounted) return;

    setState(() {
      _currentlyProcessing = true;
    });
  }

  Future<void> _stopStream() async {
    try {
      // await _localStream.dispose();
      _localStream!.getTracks().toDart.forEach((track) {
        if (track.readyState == 'live') {
          track.stop();
        }
      });
      // video.stop();
      video.srcObject = null;
      _localStream = null;
      // _localRenderer.srcObject = null;
      // ignore: empty_catches
    } catch (e) {}
  }

  Future<dynamic> _captureFrame2() async {
    if (_localStream == null) {
      return null;
    }
    final canvas = web.HTMLCanvasElement();

    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;

    final ctx = canvas.context2D;
    // canvas.width = video.videoWidth;
    // canvas.height = video.videoHeight;
    ctx.drawImage(video, 0, 0);
    final imgData = ctx.getImageData(0, 0, canvas.width, canvas.height);

    final size = Size(canvas.width.toDouble(), canvas.height.toDouble());
    if (size != _size) {
      setState(() {
        _setCanvasSize(size);
      });
    }

    try {
      final code = jsQR(imgData.data, canvas.width, canvas.height);
      // ignore: unnecessary_null_comparison
      if (code != null && code.data != null) {
        _scanUpdateController
            .add(Barcode(code.data, BarcodeFormat.qrcode, code.data.codeUnits));
      }
    } on NoSuchMethodError {
      // Do nothing, this exception occurs continously in web release when no
      // code is found.
      // NoSuchMethodError: method not found: 'get$data' on null
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Center(child: Text(_errorMsg!));
    }
    if (_localStream == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        var zoom = 1.0;

        if (_size.height != 0) zoom = constraints.maxHeight / _size.height;

        if (_size.width != 0) {
          final horizontalZoom = constraints.maxWidth / _size.width;
          if (horizontalZoom > zoom) {
            zoom = horizontalZoom;
          }
        }

        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Center(
            child: SizedBox.fromSize(
              size: _size,
              child: Transform.scale(
                alignment: Alignment.center,
                scale: zoom,
                child: HtmlElementView(viewType: viewID),
              ),
            ),
          ),
        );
      },
    );
  }

  void _setCanvasSize(ui.Size size) {
    setState(() {
      _size = size;
    });
  }
}

class QRViewControllerWeb implements QRViewController {
  final _WebQrViewState _state;

  QRViewControllerWeb(this._state);
  @override
  void dispose() => _state.cancel();

  @override
  Future<CameraFacing> flipCamera() async {
    // TODO: improve error handling
    _state.facing = _state.facing == CameraFacing.front
        ? CameraFacing.back
        : CameraFacing.front;
    await _state.start();
    return _state.facing;
  }

  @override
  Future<CameraFacing> getCameraInfo() async {
    return _state.facing;
  }

  @override
  Future<bool?> getFlashStatus() async {
    // TODO: flash is simply not supported by JavaScipt. To avoid issuing applications, we always return it to be off.
    return false;
  }

  @override
  Future<SystemFeatures> getSystemFeatures() {
    // TODO: implement getSystemFeatures
    throw UnimplementedError();
  }

  @override
  // TODO: implement hasPermissions. Blocking: WebQrView.cameraAvailable() returns a Future<bool> whereas a bool is required
  bool get hasPermissions => throw UnimplementedError();

  @override
  Future<void> pauseCamera() {
    // TODO: implement pauseCamera
    throw UnimplementedError();
  }

  @override
  Future<void> resumeCamera() {
    // TODO: implement resumeCamera
    throw UnimplementedError();
  }

  @override
  Stream<Barcode> get scannedDataStream => _state._scanUpdateController.stream;

  @override
  Future<void> stopCamera() {
    // TODO: implement stopCamera
    throw UnimplementedError();
  }

  @override
  Future<void> toggleFlash() async {
    // TODO: flash is simply not supported by JavaScipt
    return;
  }

  @override
  Future<void> scanInvert(bool isScanInvert) {
    // TODO: implement scanInvert
    throw UnimplementedError();
  }
}

Widget createWebQrView(
        {onPlatformViewCreated, onPermissionSet, CameraFacing? cameraFacing}) =>
    WebQrView(
      onPlatformViewCreated: onPlatformViewCreated,
      onPermissionSet: onPermissionSet,
      cameraFacing: cameraFacing,
    );
