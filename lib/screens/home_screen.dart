import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/load_sample.dart';
import '../services/tindeq_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TindeqService _tindeq = TindeqService();
  final List<StreamSubscription> _subs = [];
  final Queue<FlSpot> _chartData = Queue<FlSpot>();

  static const int _maxChartPoints = 500;
  static const double _chartWindowSeconds = 10.0;

  double _currentLoad = 0.0;
  double _peakLoad = 0.0;
  double? _batteryVoltage;
  TindeqConnectionState _connectionState = TindeqConnectionState.disconnected;
  final List<String> _logs = [];
  double _elapsedSeconds = 0.0;

  @override
  void initState() {
    super.initState();
    _subs.add(_tindeq.loadStream.listen(_onLoad));
    _subs.add(_tindeq.stateStream.listen(_onStateChange));
    _subs.add(_tindeq.peakLoadStream.listen(_onPeakLoad));
    _subs.add(_tindeq.batteryStream.listen(_onBattery));
    _subs.add(_tindeq.logStream.listen(_onLog));
  }

  void _onLoad(LoadSample sample) {
    setState(() {
      _currentLoad = sample.weightKg;
      _elapsedSeconds = sample.timestamp.inMicroseconds / 1e6;

      _chartData.addLast(FlSpot(_elapsedSeconds, sample.weightKg));
      while (_chartData.length > _maxChartPoints) {
        _chartData.removeFirst();
      }
    });
  }

  void _onStateChange(TindeqConnectionState state) {
    setState(() {
      _connectionState = state;
      if (state == TindeqConnectionState.disconnected) {
        _currentLoad = 0.0;
      }
    });
  }

  void _onPeakLoad(double peak) {
    setState(() => _peakLoad = peak);
  }

  void _onBattery(double voltage) {
    setState(() => _batteryVoltage = voltage);
  }

  void _onLog(String message) {
    setState(() {
      _logs.add(message);
      if (_logs.length > 50) _logs.removeAt(0);
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _tindeq.dispose();
    super.dispose();
  }

  bool get _isConnected =>
      _connectionState == TindeqConnectionState.connected ||
      _connectionState == TindeqConnectionState.measuring;

  bool get _isMeasuring =>
      _connectionState == TindeqConnectionState.measuring;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Tindeq Progressor'),
        backgroundColor: const Color(0xFF1E1E1E),
        actions: [
          if (_batteryVoltage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Icon(Icons.battery_full, size: 18),
                  const SizedBox(width: 4),
                  Text('${_batteryVoltage!.toStringAsFixed(2)}V'),
                ],
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          _buildLoadDisplay(),
          _buildChart(),
          _buildControls(),
          _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _buildLoadDisplay() {
    final loadColor = _currentLoad < 10
        ? Colors.greenAccent
        : _currentLoad < 30
            ? Colors.orangeAccent
            : Colors.redAccent;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          Text(
            _currentLoad.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 72,
              fontWeight: FontWeight.bold,
              color: loadColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const Text(
            'kg',
            style: TextStyle(fontSize: 20, color: Colors.white54),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildStatChip('Peak', '${_peakLoad.toStringAsFixed(1)} kg',
                  Colors.orangeAccent),
              const SizedBox(width: 16),
              _buildStatChip(
                'Status',
                _connectionStateLabel(),
                _connectionStateColor(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: color.withAlpha(180))),
          Text(value,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  String _connectionStateLabel() {
    switch (_connectionState) {
      case TindeqConnectionState.disconnected:
        return 'Disconnected';
      case TindeqConnectionState.scanning:
        return 'Scanning...';
      case TindeqConnectionState.connecting:
        return 'Connecting...';
      case TindeqConnectionState.connected:
        return 'Connected';
      case TindeqConnectionState.measuring:
        return 'Measuring';
    }
  }

  Color _connectionStateColor() {
    switch (_connectionState) {
      case TindeqConnectionState.disconnected:
        return Colors.grey;
      case TindeqConnectionState.scanning:
      case TindeqConnectionState.connecting:
        return Colors.blueAccent;
      case TindeqConnectionState.connected:
        return Colors.greenAccent;
      case TindeqConnectionState.measuring:
        return Colors.tealAccent;
    }
  }

  Widget _buildChart() {
    final spots = _chartData.toList();

    double minX = 0;
    double maxX = _chartWindowSeconds;
    if (spots.isNotEmpty) {
      maxX = spots.last.x;
      minX = max(0, maxX - _chartWindowSeconds);
    }

    // Compute a nice Y max
    double maxY = 10;
    for (final s in spots) {
      if (s.y > maxY) maxY = s.y;
    }
    maxY = ((maxY / 10).ceil() * 10).toDouble();
    if (maxY < 10) maxY = 10;

    return Expanded(
      flex: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
        child: LineChart(
          LineChartData(
            minX: minX,
            maxX: maxX,
            minY: 0,
            maxY: maxY,
            clipData: const FlClipData.all(),
            gridData: FlGridData(
              show: true,
              drawHorizontalLine: true,
              drawVerticalLine: false,
              horizontalInterval: maxY / 5,
              getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.white10,
                strokeWidth: 0.5,
              ),
            ),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 44,
                  interval: maxY / 5,
                  getTitlesWidget: (value, meta) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      value.toStringAsFixed(0),
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                ),
              ),
              bottomTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
            ),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                curveSmoothness: 0.15,
                color: Colors.tealAccent,
                barWidth: 2.5,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.tealAccent.withAlpha(80),
                      Colors.tealAccent.withAlpha(0),
                    ],
                  ),
                ),
              ),
            ],
            lineTouchData: const LineTouchData(enabled: false),
          ),
          duration: Duration.zero,
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          // Connect / Disconnect
          Expanded(
            child: _isConnected
                ? OutlinedButton.icon(
                    onPressed: _tindeq.disconnect,
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: const Text('Disconnect'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: _connectionState ==
                                TindeqConnectionState.scanning ||
                            _connectionState ==
                                TindeqConnectionState.connecting
                        ? null
                        : _tindeq.scanAndConnect,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Connect'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          // Start / Stop measurement
          Expanded(
            child: _isMeasuring
                ? ElevatedButton.icon(
                    onPressed: _tindeq.stopMeasurement,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                  )
                : ElevatedButton.icon(
                    onPressed: _isConnected ? _tindeq.startMeasurement : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          // Tare
          IconButton(
            onPressed: _isConnected ? _tindeq.tare : null,
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Tare',
            style: IconButton.styleFrom(
              foregroundColor: Colors.white70,
              backgroundColor: Colors.white10,
            ),
          ),
          const SizedBox(width: 4),
          // Battery
          IconButton(
            onPressed: _isConnected ? _tindeq.requestBattery : null,
            icon: const Icon(Icons.battery_unknown),
            tooltip: 'Battery',
            style: IconButton.styleFrom(
              foregroundColor: Colors.white70,
              backgroundColor: Colors.white10,
            ),
          ),
          const SizedBox(width: 4),
          // Reset peak
          IconButton(
            onPressed: () {
              _tindeq.resetPeak();
              setState(() {
                _chartData.clear();
              });
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset',
            style: IconButton.styleFrom(
              foregroundColor: Colors.white70,
              backgroundColor: Colors.white10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    return Expanded(
      flex: 1,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListView.builder(
          reverse: true,
          itemCount: _logs.length,
          itemBuilder: (context, index) {
            final logIndex = _logs.length - 1 - index;
            return Text(
              _logs[logIndex],
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            );
          },
        ),
      ),
    );
  }
}
