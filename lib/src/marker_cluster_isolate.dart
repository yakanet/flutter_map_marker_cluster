import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_map/plugin_api.dart';
import 'package:flutter_map_marker_cluster/src/core/distance_grid.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_cluster_node.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_node.dart';
import 'package:latlong/latlong.dart';

class RecalculateOptions {
  final int maxZoom;
  final int minZoom;
  final double zoom;
  final List<Marker> markers;
  final int maxClusterRadius;

  RecalculateOptions({
    this.maxZoom,
    this.minZoom,
    this.zoom,
    this.markers,
    this.maxClusterRadius,
  });

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'maxZoom': maxZoom,
      'minZoom': minZoom,
      'zoom': zoom,
      'maxClusterRadius': maxClusterRadius,
      'markers': markers
          .map((marker) => {
                'point': {
                  'latitude': marker.point.latitude,
                  'longitude': marker.point.longitude,
                },
                'width': marker.width,
                'height': marker.height,
                'anchor': {
                  'left': marker.anchor.left,
                  'top': marker.anchor.top,
                },
              })
          .toList(growable: false)
    };
  }

  factory RecalculateOptions.fromJson(Map<String, dynamic> json) {
    return RecalculateOptions(
      minZoom: json['minZoom'],
      maxZoom: json['maxZoom'],
      zoom: json['zoom'],
      maxClusterRadius: json['maxClusterRadius'],
      markers: (json['markers'] as List<dynamic>)
          .map(
            (e) => Marker(
              width: e['width'],
              height: e['height'],
              anchorPos: AnchorPos.exactly(
                  Anchor(e['anchor']['left'], e['anchor']['right'])),
              point: LatLng(e['point']['latitude'], e['point']['longitude']),
            ),
          )
          .toList(growable: false),
    );
  }
}

class RecalculateResult {
  final Map<int, DistanceGrid<MarkerClusterNode>> gridClusters;
  final Map<int, DistanceGrid<MarkerNode>> gridUnclustered;
  final MarkerClusterNode topClusterLevel;

  RecalculateResult(
    this.topClusterLevel,
    this.gridClusters,
    this.gridUnclustered,
  );
}

class MapMockState extends MapState {
  MapMockState(double zoom) : super(MapOptions(zoom: zoom));
}

class _RecalculateContext {
  final gridClusters = <int, DistanceGrid<MarkerClusterNode>>{};
  final gridUnclustered = <int, DistanceGrid<MarkerNode>>{};
  MarkerClusterNode topClusterLevel;
  final RecalculateOptions options;
  final MapState map;

  _RecalculateContext(this.options) : map = MapMockState(options.zoom);

  void initializeClusters() {
    // set up DistanceGrids for each zoom
    for (var zoom = options.maxZoom; zoom >= options.minZoom; zoom--) {
      gridClusters[zoom] = DistanceGrid(options.maxClusterRadius);
      gridUnclustered[zoom] = DistanceGrid(options.maxClusterRadius);
    }

    topClusterLevel = MarkerClusterNode(
      zoom: options.minZoom - 1,
      map: map,
    );
  }

  addLayers() {
    for (var marker in options.markers) {
      addLayer(MarkerNode(marker));
    }
    topClusterLevel.recalculateBounds();
  }

  addLayer(MarkerNode marker) {
    for (var zoom = options.maxZoom; zoom >= options.minZoom; zoom--) {
      var markerPoint = map.project(marker.point, zoom.toDouble());
      // try find a cluster close by
      var cluster = gridClusters[zoom].getNearObject(markerPoint);
      if (cluster != null) {
        cluster.addChild(marker);
        return;
      }

      var closest = gridUnclustered[zoom].getNearObject(markerPoint);
      if (closest != null) {
        var parent = closest.parent;
        parent.removeChild(closest);

        var newCluster = MarkerClusterNode(zoom: zoom, map: map)
          ..addChild(closest)
          ..addChild(marker);

        gridClusters[zoom].addObject(
            newCluster, map.project(newCluster.point, zoom.toDouble()));

        //First create any new intermediate parent clusters that don't exist
        var lastParent = newCluster;
        for (var z = zoom - 1; z > parent.zoom; z--) {
          var newParent = MarkerClusterNode(zoom: z, map: map);
          newParent.addChild(lastParent);
          lastParent = newParent;
          gridClusters[z]
              .addObject(lastParent, map.project(closest.point, z.toDouble()));
        }
        parent.addChild(lastParent);
        _removeFromNewPosToMyPosGridUnclustered(closest, zoom);
        return;
      }

      gridUnclustered[zoom].addObject(marker, markerPoint);
    }

    //Didn't get in anything, add us to the top
    topClusterLevel.addChild(marker);
  }

  _removeFromNewPosToMyPosGridUnclustered(MarkerNode marker, int zoom) {
    for (; zoom >= options.minZoom; zoom--) {
      if (!gridUnclustered[zoom].removeObject(marker)) {
        break;
      }
    }
  }
}

class Worker {
  Isolate _isolate;
  final _isolateReady = Completer<SendPort>();
  final _streamController = StreamController<MarkerClusterNode>();

  Worker() {
    _init();
  }

  Future<void> _init() async {
    final receivePort = ReceivePort();
    receivePort.listen(_handleMessage);
    _isolate = await Isolate.spawn(_isolateEntry, receivePort.sendPort,
        debugName: 'Cluster computation');
  }

  Stream<MarkerClusterNode> get stream => _streamController.stream;

  void _handleMessage(message) {
    if (message is SendPort) {
      _isolateReady.complete(message);
      return;
    }
    if (message is RecalculateResult) {
      _streamController.add(message.topClusterLevel);
    }
  }

  dispose() {
    _streamController.close();
    _isolate.kill();
  }

  void recalculate(RecalculateOptions options) async {
    final sendPort = await _isolateReady.future;
    final _json = json.encode(options.toJson());
    sendPort.send(_json);
  }
}

_isolateEntry(SendPort message) {
  final receivePort = ReceivePort();
  if (message is SendPort) {
    message.send(receivePort.sendPort);
  }
  receivePort.listen((message) {
    final options = RecalculateOptions.fromJson(json.decode(message));
    final context = _RecalculateContext(options);
    context.initializeClusters();
    context.addLayers();
    message.send(
      RecalculateResult(
        context.topClusterLevel,
        context.gridClusters,
        context.gridUnclustered,
      ),
    );
  });
}
