import 'package:flutter/material.dart';

/// Global route observer for pages that need to refresh when becoming visible again.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
