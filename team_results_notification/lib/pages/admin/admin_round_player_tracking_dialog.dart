import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../login_page.dart';

class AdminRoundPlayerTrackingDialog extends StatefulWidget {
  final int activeGameId;
  final String roundName;
  final int userId;
  final String displayName;

  const AdminRoundPlayerTrackingDialog({
    super.key,
    required this.activeGameId,
    required this.roundName,
    required this.userId,
    required this.displayName,
  });

  static Future<void> show(
    BuildContext context, {
    required int activeGameId,
    required String roundName,
    required int userId,
    required String displayName,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AdminRoundPlayerTrackingDialog(
        activeGameId: activeGameId,
        roundName: roundName,
        userId: userId,
        displayName: displayName,
      ),
    );
  }

  @override
  State<AdminRoundPlayerTrackingDialog> createState() =>
      _AdminRoundPlayerTrackingDialogState();
}

class _AdminRoundPlayerTrackingDialogState
    extends State<AdminRoundPlayerTrackingDialog> {
  static const _liveGreen = Color(0xFF2E7D32);
  static const _liveRed = Color(0xFFC62828);
  static const _viewportWidth = 520.0;

  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _detail;
  final ScrollController _graphScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _graphScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final data = await DatabaseService.getRoundAppTrackingPlayer(
      widget.activeGameId,
      widget.roundName,
      widget.userId,
    );
    if (!mounted) return;
    if (data['success'] != true) {
      setState(() {
        _loading = false;
        _error = data['message']?.toString() ?? 'Failed to load';
      });
      return;
    }
    setState(() {
      _detail = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isVisible = _detail?['is_visible'] == true;
    final seconds = int.tryParse('${_detail?['invisible_seconds']}') ?? 0;
    final graphPoints = (_detail?['graph_points'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    return AlertDialog(
      title: Text(widget.displayName),
      content: SizedBox(
        width: _viewportWidth,
        height: (MediaQuery.sizeOf(context).height * 0.72).clamp(420.0, 640.0),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Text(_error!)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: isVisible ? _liveGreen : _liveRed,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              isVisible
                                  ? 'Visible'
                                  : 'Not visible · ${seconds}s',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Timeline',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      _buildTimelineGraph(graphPoints),
                      const SizedBox(height: 16),
                      const Text(
                        'Events',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          child: _buildEventsTable(),
                        ),
                      ),
                    ],
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: _load,
          child: const Text('Refresh'),
        ),
      ],
    );
  }

  Widget _buildTimelineGraph(List<Map<String, dynamic>> points) {
    final graphEndSec = _graphEndSec(points);
    final alignedEndSec = _alignedGraphEndSec(graphEndSec);
    final graphWidth = _TrackingStepGraphPainter.computeWidth(alignedEndSec);
    final scrollable = graphWidth > _viewportWidth - 16;

    Widget graphScrollView = ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      child: Scrollbar(
        controller: _graphScrollController,
        thumbVisibility: scrollable,
        interactive: true,
        child: SingleChildScrollView(
          controller: _graphScrollController,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          child: SizedBox(
            width: graphWidth,
            height: _TrackingStepGraphPainter.chartHeight,
            child: CustomPaint(
              painter: _TrackingStepGraphPainter(
                points: points,
                graphEndSec: graphEndSec,
                alignedEndSec: alignedEndSec,
              ),
            ),
          ),
        ),
      ),
    );

    if (scrollable) {
      graphScrollView = Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          if (!_graphScrollController.hasClients) return;

          var delta = event.scrollDelta.dx;
          if (delta == 0 &&
              HardwareKeyboard.instance.isShiftPressed &&
              event.scrollDelta.dy != 0) {
            delta = event.scrollDelta.dy;
          }
          if (delta == 0) return;

          final position = _graphScrollController.position;
          _graphScrollController.jumpTo(
            (position.pixels + delta).clamp(0.0, position.maxScrollExtent),
          );
        },
        child: graphScrollView,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (scrollable)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Drag the bar below, swipe, or Shift+scroll to view the full period (${alignedEndSec}s)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ),
        SizedBox(
          height: _TrackingStepGraphPainter.chartHeight,
          width: _viewportWidth,
          child: graphScrollView,
        ),
      ],
    );
  }

  Widget _buildEventsTable() {
    final events =
        (_detail?['events'] as List? ?? []).cast<Map<String, dynamic>>();
    if (events.isEmpty) {
      return const Text('No events recorded.');
    }

    return Table(
      columnWidths: const {
        0: FixedColumnWidth(56),
        1: FlexColumnWidth(),
        2: FlexColumnWidth(),
      },
      border: TableBorder.all(color: Colors.grey.shade300),
      children: [
        const TableRow(
          decoration: BoxDecoration(color: Color(0xFFEEEEEE)),
          children: [
            Padding(
              padding: EdgeInsets.all(6),
              child: Text('t (s)', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: EdgeInsets.all(6),
              child: Text('Reason', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            Padding(
              padding: EdgeInsets.all(6),
              child: Text('UTC', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        ...events.map((ev) {
          final offset = ev['offset_sec'];
          final reason = ev['reason']?.toString() ?? '';
          final ts = ev['timestamp']?.toString() ?? '';
          return TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(offset?.toString() ?? '—'),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(reason),
              ),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Text(
                  ts.length > 19 ? ts.substring(0, 19) : ts,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          );
        }),
      ],
    );
  }

  int _graphEndSec(List<Map<String, dynamic>> points) {
    if (points.isEmpty) return 10;
    var end = points
        .map((p) => int.tryParse('${p['t_sec']}') ?? 0)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final roundStart = _detail?['round_start_utc']?.toString();
    if (roundStart != null && roundStart.isNotEmpty) {
      try {
        final rs = DateTime.parse(roundStart).toUtc();
        final nowSec =
            DateTime.now().toUtc().difference(rs).inSeconds.clamp(0, 1 << 30);
        if (nowSec > end) end = nowSec;
      } catch (_) {}
    }
    return end > 0 ? end : 10;
  }

  int _alignedGraphEndSec(int endSec) {
    const tick = _TrackingStepGraphPainter.tickIntervalSec;
    if (endSec <= tick) return tick;
    return ((endSec + tick - 1) ~/ tick) * tick;
  }
}

class _TrackingStepGraphPainter extends CustomPainter {
  static const double pxPerSecond = 8;
  static const int tickIntervalSec = 10;
  static const double leftPadding = 4;
  static const double rightPadding = 8;
  static const double chartHeight = 172;
  static const double axisHeight = 22;

  final List<Map<String, dynamic>> points;
  final int graphEndSec;
  final int alignedEndSec;

  _TrackingStepGraphPainter({
    required this.points,
    required this.graphEndSec,
    required this.alignedEndSec,
  });

  static double computeWidth(int alignedEndSec) {
    final contentWidth = leftPadding + alignedEndSec * pxPerSecond + rightPadding;
    return contentWidth < 504 ? 504 : contentWidth;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFF5F5F5);
    canvas.drawRect(Offset.zero & size, bg);

    _drawTimeGrid(canvas, size);

    if (points.isEmpty) {
      _drawAxisLabels(canvas, size);
      return;
    }

    final plotBottom = size.height - axisHeight;
    final midY = plotBottom * 0.48;
    final visibleY = plotBottom * 0.2;
    final invisibleY = plotBottom * 0.62;

    double yFor(int y) {
      if (y > 0) return visibleY;
      if (y < 0) return invisibleY;
      return midY;
    }

    final green = Paint()
      ..color = const Color(0xFF2E7D32)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final red = Paint()
      ..color = const Color(0xFFC62828)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    double xFor(int tSec) => leftPadding + tSec * pxPerSecond;

    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final t0 = int.tryParse('${p0['t_sec']}') ?? 0;
      final t1 = int.tryParse('${p1['t_sec']}') ?? 0;
      final yVal = int.tryParse('${p0['y']}') ?? 0;
      final paint = yVal >= 0 ? green : red;
      final x0 = xFor(t0);
      final x1 = xFor(t1);
      final y = yFor(yVal);
      canvas.drawLine(Offset(x0, y), Offset(x1, y), paint);
      if (yVal < 0) {
        _drawDurationLabel(
          canvas,
          x0: x0,
          x1: x1,
          durationSec: t1 - t0,
          segmentY: y,
          labelBandTop: invisibleY + 8,
          labelBandBottom: plotBottom - 2,
        );
      }
      if (i + 1 < points.length) {
        final nextY = int.tryParse('${p1['y']}') ?? 0;
        canvas.drawLine(
          Offset(x1, y),
          Offset(x1, yFor(nextY)),
          paint,
        );
      }
    }

    final last = points.last;
    final lastT = int.tryParse('${last['t_sec']}') ?? 0;
    final lastY = int.tryParse('${last['y']}') ?? 0;
    final lastPaint = lastY >= 0 ? green : red;
    final endX = xFor(graphEndSec);
    final lastLineY = yFor(lastY);
    canvas.drawLine(
      Offset(xFor(lastT), lastLineY),
      Offset(endX, lastLineY),
      lastPaint,
    );
    if (lastY < 0) {
      _drawDurationLabel(
        canvas,
        x0: xFor(lastT),
        x1: endX,
        durationSec: graphEndSec - lastT,
        segmentY: lastLineY,
        labelBandTop: invisibleY + 8,
        labelBandBottom: plotBottom - 2,
      );
    }

    _drawAxisLabels(canvas, size);
  }

  void _drawTimeGrid(Canvas canvas, Size size) {
    final plotBottom = size.height - axisHeight;
    final gridPaint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, plotBottom), Offset(size.width, plotBottom), gridPaint);

    for (var t = 0; t <= alignedEndSec; t += tickIntervalSec) {
      final x = leftPadding + t * pxPerSecond;
      canvas.drawLine(Offset(x, 0), Offset(x, plotBottom), gridPaint);
    }
  }

  void _drawAxisLabels(Canvas canvas, Size size) {
    final plotBottom = size.height - axisHeight;
    final labelStyle = TextStyle(
      fontSize: 10,
      color: Colors.grey.shade700,
    );

    for (var t = 0; t <= alignedEndSec; t += tickIntervalSec) {
      final x = leftPadding + t * pxPerSecond;
      final tp = TextPainter(
        text: TextSpan(text: _formatTickLabel(t), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      var labelX = x - tp.width / 2;
      if (labelX < 0) labelX = 0;
      if (labelX + tp.width > size.width) labelX = size.width - tp.width;

      tp.paint(canvas, Offset(labelX, plotBottom + 4));
    }
  }

  String _formatTickLabel(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (s == 0) return '${m}m';
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  void _drawDurationLabel(
    Canvas canvas, {
    required double x0,
    required double x1,
    required int durationSec,
    required double segmentY,
    required double labelBandTop,
    required double labelBandBottom,
  }) {
    if (durationSec <= 0) return;

    final left = x0 < x1 ? x0 : x1;
    final right = x0 < x1 ? x1 : x0;
    final segmentWidth = right - left;
    final centerX = (left + right) / 2;
    final label = '${durationSec}s';

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: 11,
          color: Color(0xFF424242),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final bandHeight = labelBandBottom - labelBandTop;
    final fitsInBand = tp.width + 6 <= segmentWidth && tp.height + 2 <= bandHeight;

    if (fitsInBand) {
      final y = labelBandTop + (bandHeight - tp.height) / 2;
      tp.paint(canvas, Offset(centerX - tp.width / 2, y));
      return;
    }

    // Narrow segment: badge above the invisible line so every episode stays readable.
    const hPad = 4;
    const vPad = 2;
    final badgeW = tp.width + hPad * 2;
    final badgeH = tp.height + vPad * 2;
    var badgeLeft = centerX - badgeW / 2;
    badgeLeft = badgeLeft.clamp(0.0, double.infinity);
    final badgeTop = (segmentY - badgeH - 4).clamp(2.0, labelBandTop);

    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(badgeLeft, badgeTop, badgeW, badgeH),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      badgeRect,
      Paint()..color = const Color(0xFFFFEBEE),
    );
    canvas.drawRRect(
      badgeRect,
      Paint()
        ..color = const Color(0xFFC62828)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    tp.paint(
      canvas,
      Offset(badgeLeft + hPad, badgeTop + vPad),
    );
  }

  @override
  bool shouldRepaint(covariant _TrackingStepGraphPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.graphEndSec != graphEndSec ||
        oldDelegate.alignedEndSec != alignedEndSec;
  }
}
