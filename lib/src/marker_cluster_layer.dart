import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/plugin_api.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:flutter_map_marker_cluster/src/anim_type.dart';
import 'package:flutter_map_marker_cluster/src/core/distance_grid.dart';
import 'package:flutter_map_marker_cluster/src/core/quick_hull.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_cluster_node.dart';
import 'package:flutter_map_marker_cluster/src/node/marker_node.dart';
import 'package:flutter_map_marker_popup/extension_api.dart';
import 'package:latlong2/latlong.dart';

class MarkerClusterLayer extends StatefulWidget {
  final MarkerClusterLayerOptions options;
  final MapState map;
  final Stream<void> stream;

  MarkerClusterLayer(this.options, this.map, this.stream);

  @override
  _MarkerClusterLayerState createState() => _MarkerClusterLayerState();
}

class _MarkerClusterLayerState extends State<MarkerClusterLayer>
    with TickerProviderStateMixin {
  final Map<int, DistanceGrid<MarkerClusterNode>> _gridClusters = {};
  final Map<int, DistanceGrid<MarkerNode>> _gridUnclustered = {};
  late MarkerClusterNode _topClusterLevel;
  late int _maxZoom;
  late int _minZoom;
  late int _currentZoom;
  late int _previousZoom;
  late double _previousZoomDouble;
  late AnimationController _zoomController;
  late AnimationController _fitBoundController;
  late AnimationController _centerMarkerController;
  late AnimationController _spiderfyController;
  MarkerClusterNode? _spiderfyCluster;
  PolygonLayer? _polygon;

  _MarkerClusterLayerState();

  CustomPoint<num> _getPixelFromPoint(LatLng point) {
    var pos = widget.map.project(point);
    return pos.multiplyBy(
            widget.map.getZoomScale(widget.map.zoom, widget.map.zoom)) -
        widget.map.getPixelOrigin();
  }

  Point _getPixelFromMarker(MarkerNode marker, [LatLng? customPoint]) {
    final pos = _getPixelFromPoint(customPoint ?? marker.point);
    return _removeAnchor(pos, marker.width, marker.height, marker.anchor);
  }

  Point _getPixelFromCluster(MarkerClusterNode cluster, [LatLng? customPoint]) {
    final pos = _getPixelFromPoint(customPoint ?? cluster.point);

    var size = getClusterSize(cluster);
    var anchor = Anchor.forPos(widget.options.anchor, size.width, size.height);

    return _removeAnchor(pos, size.width, size.height, anchor);
  }

  Point _removeAnchor(Point pos, double width, double height, Anchor anchor) {
    final x = (pos.x - (width - anchor.left)).toDouble();
    final y = (pos.y - (height - anchor.top)).toDouble();
    return Point(x, y);
  }

  void _initializeAnimationController() {
    _zoomController = AnimationController(
      vsync: this,
      duration: widget.options.animationsOptions.zoom,
    );

    _fitBoundController = AnimationController(
      vsync: this,
      duration: widget.options.animationsOptions.fitBound,
    );

    _centerMarkerController = AnimationController(
      vsync: this,
      duration: widget.options.animationsOptions.centerMarker,
    );

    _spiderfyController = AnimationController(
      vsync: this,
      duration: widget.options.animationsOptions.spiderfy,
    );
  }

  void _initializeClusters() {
    // set up DistanceGrids for each zoom
    for (var zoom = _maxZoom; zoom >= _minZoom; zoom--) {
      _gridClusters[zoom] = DistanceGrid(widget.options.maxClusterRadius);
      _gridUnclustered[zoom] = DistanceGrid(widget.options.maxClusterRadius);
    }

    _topClusterLevel = MarkerClusterNode(
      zoom: _minZoom - 1,
      map: widget.map,
    );
  }

  void _addLayer(MarkerNode marker, int disableClusteringAtZoom) {
    for (var zoom = _maxZoom; zoom >= _minZoom; zoom--) {
      var markerPoint = widget.map.project(marker.point, zoom.toDouble());
      if (zoom <= disableClusteringAtZoom) {
        // try find a cluster close by
        var cluster = _gridClusters[zoom]!.getNearObject(markerPoint);
        if (cluster != null) {
          cluster.addChild(marker);
          return;
        }

        var closest = _gridUnclustered[zoom]!.getNearObject(markerPoint);
        if (closest != null) {
          var parent = closest.parent!;
          parent.removeChild(closest);

          var newCluster = MarkerClusterNode(zoom: zoom, map: widget.map)
            ..addChild(closest)
            ..addChild(marker);

          _gridClusters[zoom]!.addObject(newCluster,
              widget.map.project(newCluster.point, zoom.toDouble()));

          //First create any new intermediate parent clusters that don't exist
          var lastParent = newCluster;
          for (var z = zoom - 1; z > parent.zoom; z--) {
            var newParent = MarkerClusterNode(
              zoom: z,
              map: widget.map,
            );
            newParent.addChild(lastParent);
            lastParent = newParent;
            _gridClusters[z]!.addObject(
                lastParent, widget.map.project(closest.point, z.toDouble()));
          }
          parent.addChild(lastParent);

          _removeFromNewPosToMyPosGridUnclustered(closest, zoom);
          return;
        }
      }

      _gridUnclustered[zoom]!.addObject(marker, markerPoint);
    }

    //Didn't get in anything, add us to the top
    _topClusterLevel.addChild(marker);
  }

  void _addLayers() {
    for (var marker in widget.options.markers) {
      _addLayer(MarkerNode(marker), widget.options.disableClusteringAtZoom);
    }

    _topClusterLevel.recalculateBounds();
  }

  void _removeFromNewPosToMyPosGridUnclustered(MarkerNode marker, int zoom) {
    for (; zoom >= _minZoom; zoom--) {
      if (!_gridUnclustered[zoom]!.removeObject(marker)) {
        break;
      }
    }
  }

  Widget _buildMarker(MarkerNode marker, AnimationController controller,
      [FadeType fade = FadeType.None,
      TranslateType translate = TranslateType.None,
      Point? newPos,
      Point? myPos]) {
    assert((translate == TranslateType.None && newPos == null) ||
        (translate != TranslateType.None && newPos != null));

    final pos = myPos ?? _getPixelFromMarker(marker);

    return Positioned(
      width: marker.width,
      height: marker.height,
      left: pos.x as double,
      top: pos.y as double,
      child: Transform.rotate(
        angle: -widget.map.rotationRad,
        origin: marker.rotateOrigin ?? widget.options.rotateOrigin,
        alignment: marker.rotateAlignment ?? widget.options.rotateAlignment,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onMarkerTap(marker) as void Function()?,
          child: marker.builder(context),
        ),
      ),
    );
  }

  List<Marker> getClusterMarkers(MarkerClusterNode cluster) =>
      cluster.markers.map((node) => node.marker).toList();

  Size getClusterSize(MarkerClusterNode cluster) =>
      widget.options.computeSize == null
          ? widget.options.size
          : widget.options.computeSize!(getClusterMarkers(cluster));

  Widget _buildCluster(MarkerClusterNode cluster,
      [FadeType fade = FadeType.None,
      TranslateType translate = TranslateType.None,
      Point? newPos]) {
    assert((translate == TranslateType.None && newPos == null) ||
        (translate != TranslateType.None && newPos != null));

    final pos = _getPixelFromCluster(cluster);

    var size = getClusterSize(cluster);

    return Positioned(
      width: size.width,
      height: size.height,
      left: pos.x as double,
      top: pos.y as double,
      child: Transform.rotate(
        angle: -widget.map.rotationRad,
        origin: widget.options.rotateOrigin,
        alignment: widget.options.rotateAlignment,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onClusterTap(cluster) as void Function()?,
          child: widget.options.builder(
            context,
            getClusterMarkers(cluster),
          ),
        ),
      ),
    );
  }

  void _spiderfy(MarkerClusterNode cluster) {
    if (_spiderfyCluster != null) {
      _unspiderfy();
      return;
    }

    setState(() {
      _spiderfyCluster = cluster;
    });
    _spiderfyController.forward();
  }

  void _unspiderfy() {
    switch (_spiderfyController.status) {
      case AnimationStatus.completed:
        var markersGettingClustered = _spiderfyCluster!.markers
            .map((markerNode) => markerNode.marker)
            .toList();

        _spiderfyController.reverse().then((_) => setState(() {
              _spiderfyCluster = null;
            }));

        if (widget.options.popupOptions != null) {
          widget.options.popupOptions!.popupController
              .hidePopupsOnlyFor(markersGettingClustered);
        }
        if (widget.options.onMarkersClustered != null) {
          widget.options.onMarkersClustered!(markersGettingClustered);
        }
        break;
      case AnimationStatus.forward:
        var markersGettingClustered = _spiderfyCluster!.markers
            .map((markerNode) => markerNode.marker)
            .toList();

        _spiderfyController
          ..stop()
          ..reverse().then((_) => setState(() {
                _spiderfyCluster = null;
              }));

        if (widget.options.popupOptions != null) {
          widget.options.popupOptions!.popupController
              .hidePopupsOnlyFor(markersGettingClustered);
        }
        if (widget.options.onMarkersClustered != null) {
          widget.options.onMarkersClustered!(markersGettingClustered);
        }
        break;
      default:
        break;
    }
  }

  bool _boundsContainsMarker(MarkerNode marker) {
    var pixelPoint = widget.map.project(marker.point);

    final width = marker.width - marker.anchor.left;
    final height = marker.height - marker.anchor.top;

    var sw = CustomPoint(pixelPoint.x + width, pixelPoint.y - height);
    var ne = CustomPoint(pixelPoint.x - width, pixelPoint.y + height);
    return widget.map.pixelBounds.containsPartialBounds(Bounds(sw, ne));
  }

  bool _boundsContainsCluster(MarkerClusterNode cluster) {
    var pixelPoint = widget.map.project(cluster.point);

    var size = getClusterSize(cluster);
    var anchor = Anchor.forPos(widget.options.anchor, size.width, size.height);

    final width = size.width - anchor.left;
    final height = size.height - anchor.top;

    var sw = CustomPoint(pixelPoint.x + width, pixelPoint.y - height);
    var ne = CustomPoint(pixelPoint.x - width, pixelPoint.y + height);
    return widget.map.pixelBounds.containsPartialBounds(Bounds(sw, ne));
  }

  List<Widget> _buildLayer(layer) {
    var layers = <Widget>[];

    if (layer is MarkerNode) {
      if (!_boundsContainsMarker(layer)) {
        return <Widget>[];
      }
      layers.add(
        _buildMarker(
          layer,
          _zoomController,
          FadeType.FadeIn,
          TranslateType.FromNewPosToMyPos,
          _getPixelFromMarker(layer, layer.parent!.point),
        ),
      );
    }
    if (layer is MarkerClusterNode) {
      if (!_boundsContainsCluster(layer)) {
        return <Widget>[];
      }
      layers.add(
        _buildCluster(
          layer,
          FadeType.FadeOut,
          TranslateType.FromMyPosToNewPos,
          _getPixelFromCluster(layer, layer.point),
        ),
      );
    }

    return layers;
  }

  List<Widget> _buildLayers() {
    if (widget.map.zoom != _previousZoomDouble) {
      _previousZoomDouble = widget.map.zoom;

      _unspiderfy();
    }

    var zoom = widget.map.zoom.ceil();

    var layers = <Widget>[];

    if (_polygon != null) layers.add(_polygon!);

    if (zoom < _currentZoom || zoom > _currentZoom) {
      _previousZoom = _currentZoom;
      _currentZoom = zoom;

      _zoomController
        ..reset()
        ..forward().then((_) => setState(() {
              _hidePolygon();
            })); // for remove previous layer (animation)
    }

    _topClusterLevel.recursively(
        _currentZoom, widget.options.disableClusteringAtZoom, (layer) {
      layers.addAll(_buildLayer(layer));
    });

    final popupOptions = widget.options.popupOptions;
    if (popupOptions != null) {
      layers.add(PopupLayer(
        popupState: PopupState.maybeOf(context, listen: false) ?? PopupState(),
        popupBuilder: popupOptions.popupBuilder,
        popupSnap: popupOptions.popupSnap,
        popupController: popupOptions.popupController,
        popupAnimation: popupOptions.popupAnimation,
        markerRotate: popupOptions.markerRotate,
        mapState: widget.map,
      ));
    }

    return layers;
  }

  Function _onClusterTap(MarkerClusterNode cluster) {
    return () {
      if (_zoomController.isAnimating ||
          _centerMarkerController.isAnimating ||
          _fitBoundController.isAnimating ||
          _spiderfyController.isAnimating) {
        return null;
      }

      // This is handled as an optional callback rather than leaving the package
      // user to wrap their cluster Marker child Widget in a GestureDetector as only one
      // GestureDetector gets triggered per gesture (usually the child one) and
      // therefore this _onClusterTap() function never gets called.
      if (widget.options.onClusterTap != null) {
        widget.options.onClusterTap!(cluster);
      }

      if (!widget.options.zoomToBoundsOnClick) {
        _spiderfy(cluster);
        return null;
      }

      final center = widget.map.center;
      var dest = widget.map
          .getBoundsCenterZoom(cluster.bounds, widget.options.fitBoundsOptions);

      // check if children can un-cluster
      var cannotDivide = cluster.markers.every((marker) =>
              marker.parent!.zoom == _maxZoom &&
              marker.parent == cluster.markers[0].parent) ||
          (dest.zoom == _currentZoom &&
              _currentZoom == widget.options.fitBoundsOptions.maxZoom);

      if (cannotDivide) {
        dest = CenterZoom(center: dest.center, zoom: _currentZoom.toDouble());
      }

      if (dest.zoom > _currentZoom && !cannotDivide) {
        _showPolygon(cluster.markers.fold<List<LatLng>>(
            [], (result, marker) => result..add(marker.point)));
      }

      final _latTween =
          Tween<double>(begin: center.latitude, end: dest.center.latitude);
      final _lngTween =
          Tween<double>(begin: center.longitude, end: dest.center.longitude);
      final _zoomTween =
          Tween<double>(begin: _currentZoom.toDouble(), end: dest.zoom);

      Animation<double> animation = CurvedAnimation(
          parent: _fitBoundController,
          curve: widget.options.animationsOptions.fitBoundCurves);

      final listener = () {
        widget.map.move(
            LatLng(
                _latTween.evaluate(animation), _lngTween.evaluate(animation)),
            _zoomTween.evaluate(animation),
            source: MapEventSource.custom);
      };

      _fitBoundController.addListener(listener);

      _fitBoundController.forward().then((_) {
        _fitBoundController
          ..removeListener(listener)
          ..reset();

        if (cannotDivide) {
          _spiderfy(cluster);
        }
      });
    };
  }

  void _showPolygon(List<LatLng> points) {
    if (widget.options.showPolygon) {
      setState(() {
        _polygon = PolygonLayer(
          PolygonLayerOptions(polygons: [
            Polygon(
              points: QuickHull.getConvexHull(points),
              borderStrokeWidth:
                  widget.options.polygonOptions.borderStrokeWidth,
              color: widget.options.polygonOptions.color,
              borderColor: widget.options.polygonOptions.borderColor,
              isDotted: widget.options.polygonOptions.isDotted,
            ),
          ]),
          widget.map,
          widget.stream,
        );
      });
    }
  }

  void _hidePolygon() {
    if (widget.options.showPolygon) {
      setState(() {
        _polygon = null;
      });
    }
  }

  Function _onMarkerTap(MarkerNode marker) {
    return () {
      if (_zoomController.isAnimating ||
          _centerMarkerController.isAnimating ||
          _fitBoundController.isAnimating) return null;

      if (widget.options.popupOptions != null) {
        final popupOptions = widget.options.popupOptions!;
        popupOptions.markerTapBehavior.apply(
          marker.marker,
          PopupState.maybeOf(context, listen: false) ?? PopupState(),
          popupOptions.popupController,
        );
      }

      // This is handled as an optional callback rather than leaving the package
      // user to wrap their Marker child Widget in a GestureDetector as only one
      // GestureDetector gets triggered per gesture (usually the child one) and
      // therefore this _onMarkerTap function never gets called.
      if (widget.options.onMarkerTap != null) {
        widget.options.onMarkerTap!(marker.marker);
      }

      if (!widget.options.centerMarkerOnClick) return null;

      final center = widget.map.center;

      final _latTween =
          Tween<double>(begin: center.latitude, end: marker.point.latitude);
      final _lngTween =
          Tween<double>(begin: center.longitude, end: marker.point.longitude);

      Animation<double> animation = CurvedAnimation(
          parent: _centerMarkerController,
          curve: widget.options.animationsOptions.centerMarkerCurves);

      final listener = () {
        widget.map.move(
            LatLng(
                _latTween.evaluate(animation), _lngTween.evaluate(animation)),
            widget.map.zoom,
            source: MapEventSource.custom);
      };

      _centerMarkerController.addListener(listener);

      _centerMarkerController.forward().then((_) {
        _centerMarkerController
          ..removeListener(listener)
          ..reset();
      });
    };
  }

  @override
  void initState() {
    _currentZoom = _previousZoom = widget.map.zoom.ceil();
    _previousZoomDouble = widget.map.zoom;
    _minZoom = widget.map.options.minZoom?.ceil() ?? 1;
    _maxZoom = widget.map.options.maxZoom?.floor() ?? 20;
    _previousZoomDouble = widget.map.zoom;
    _initializeAnimationController();
    _initializeClusters();
    _addLayers();

    _zoomController.forward();

    super.initState();
  }

  @override
  void dispose() {
    _zoomController.dispose();
    _fitBoundController.dispose();
    _centerMarkerController.dispose();
    _spiderfyController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MarkerClusterLayer oldWidget) {
    if (oldWidget.options.markers != widget.options.markers) {
      _initializeClusters();
      _addLayers();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: widget.stream, // a Stream<void> or null
      builder: (BuildContext context, _) {
        return Container(
          child: Stack(
            children: _buildLayers(),
          ),
        );
      },
    );
  }
}
