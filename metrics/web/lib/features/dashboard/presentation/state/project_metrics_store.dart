import 'dart:async';
import 'dart:math';

import 'package:metrics/features/dashboard/domain/entities/collections/date_time_set.dart';
import 'package:metrics/features/dashboard/domain/entities/metrics/build_result_metric.dart';
import 'package:metrics/features/dashboard/domain/entities/metrics/dashboard_project_metrics.dart';
import 'package:metrics/features/dashboard/domain/entities/metrics/performance_metric.dart';
import 'package:metrics/features/dashboard/domain/usecases/parameters/project_id_param.dart';
import 'package:metrics/features/dashboard/domain/usecases/receive_project_metrics_updates.dart';
import 'package:metrics/features/dashboard/domain/usecases/receive_project_updates.dart';
import 'package:metrics/features/dashboard/presentation/model/build_result_bar_data.dart';
import 'package:metrics/features/dashboard/presentation/model/project_metrics_data.dart';
import 'package:metrics_core/metrics_core.dart';
import 'package:rxdart/rxdart.dart';

/// The store for the project metrics.
///
/// Stores the [Project]s and their [DashboardProjectMetrics].
class ProjectMetricsStore {
  final ReceiveProjectUpdates _receiveProjectsUpdates;
  final ReceiveProjectMetricsUpdates _receiveProjectMetricsUpdates;
  final Map<String, StreamSubscription> _buildMetricsSubscriptions = {};
  final BehaviorSubject<Map<String, ProjectMetricsData>>
      _projectsMetricsSubject = BehaviorSubject();

  StreamSubscription _projectsSubscription;

  /// Creates the project metrics store.
  ///
  /// The provided use cases should not be null.
  ProjectMetricsStore(
    this._receiveProjectsUpdates,
    this._receiveProjectMetricsUpdates,
  ) : assert(
          _receiveProjectsUpdates != null &&
              _receiveProjectMetricsUpdates != null,
          'The use cases should not be null',
        );

  Stream<List<ProjectMetricsData>> get projectsMetrics =>
      _projectsMetricsSubject.map((metricsMap) => metricsMap.values.toList());

  /// Subscribes to projects and its metrics.
  Future<void> subscribeToProjects() async {
    final projectsStream = _receiveProjectsUpdates();
    await _projectsSubscription?.cancel();

    _projectsSubscription = projectsStream.listen(_projectsListener);
  }

  /// Unsubscribes from projects and it's metrics.
  Future<void> unsubscribeFromProjects() async {
    await _cancelSubscriptions();
    _projectsMetricsSubject.add({});
  }

  /// Listens to project updates.
  void _projectsListener(List<Project> newProjects) {
    if (newProjects == null || newProjects.isEmpty) {
      _projectsMetricsSubject.add({});
      return;
    }

    final projectsMetrics = _projectsMetricsSubject.value ?? {};

    final projectIds = newProjects.map((project) => project.id);
    projectsMetrics.removeWhere((projectId, value) {
      final remove = !projectIds.contains(projectId);
      if (remove) {
        _buildMetricsSubscriptions.remove(projectId)?.cancel();
      }

      return remove;
    });

    for (final project in newProjects) {
      final projectId = project.id;

      ProjectMetricsData projectMetrics =
          projectsMetrics[projectId] ?? const ProjectMetricsData();

      if (projectMetrics.projectName != project.name) {
        projectMetrics = projectMetrics.copyWith(
          projectName: project.name,
        );
      }

      if (!projectsMetrics.containsKey(projectId)) {
        _subscribeToBuildMetrics(projectId);
      }
      projectsMetrics[projectId] = projectMetrics;
    }

    _projectsMetricsSubject.add(projectsMetrics);
  }

  /// Subscribes to project metrics.
  void _subscribeToBuildMetrics(String projectId) {
    final dashboardMetricsStream = _receiveProjectMetricsUpdates(
      ProjectIdParam(projectId),
    );

    _buildMetricsSubscriptions[projectId] =
        dashboardMetricsStream.listen((metrics) {
      _createProjectMetrics(metrics, projectId);
    });
  }

  /// Creates project metrics from [DashboardProjectMetrics].
  void _createProjectMetrics(
      DashboardProjectMetrics dashboardMetrics, String projectId) {
    final projectsMetrics = _projectsMetricsSubject.value;

    final projectMetrics = projectsMetrics[projectId];

    if (projectMetrics == null || dashboardMetrics == null) return;

    final performanceMetrics = _getPerformanceMetrics(
      dashboardMetrics.performanceMetrics,
    );
    final buildResultMetrics = _getBuildResultMetrics(
      dashboardMetrics.buildResultMetrics,
    );
    final averageBuildDuration =
        dashboardMetrics.performanceMetrics.averageBuildDuration.inMinutes;
    final numberOfBuilds = dashboardMetrics.buildNumberMetrics.numberOfBuilds;

    projectsMetrics[projectId] = projectMetrics.copyWith(
      performanceMetrics: performanceMetrics,
      buildResultMetrics: buildResultMetrics,
      buildNumberMetric: numberOfBuilds,
      averageBuildDurationInMinutes: averageBuildDuration,
      coverage: dashboardMetrics.coverage,
      stability: dashboardMetrics.stability,
    );

    _projectsMetricsSubject.add(projectsMetrics);
  }

  /// Creates the project performance metrics from [PerformanceMetric].
  List<Point<int>> _getPerformanceMetrics(PerformanceMetric metric) {
    final performanceMetrics = metric?.buildsPerformance ?? DateTimeSet();

    if (performanceMetrics.isEmpty) {
      return [];
    }

    return performanceMetrics.map((metric) {
      return Point(
        metric.date.millisecondsSinceEpoch,
        metric.duration.inMilliseconds,
      );
    }).toList();
  }

  /// Creates the project build result metrics from [BuildResultMetric].
  List<BuildResultBarData> _getBuildResultMetrics(BuildResultMetric metrics) {
    final buildResults = metrics?.buildResults ?? [];

    if (buildResults.isEmpty) {
      return [];
    }

    return buildResults.map((result) {
      return BuildResultBarData(
        url: result.url,
        buildStatus: result.buildStatus,
        value: result.duration.inMilliseconds,
      );
    }).toList();
  }

  /// Cancels all created subscriptions.
  Future<void> _cancelSubscriptions() async {
    await _projectsSubscription?.cancel();
    for (final subscription in _buildMetricsSubscriptions.values) {
      await subscription?.cancel();
    }
    _buildMetricsSubscriptions.clear();
  }

  /// Cancels all subscriptions and closes all created streams.
  Future<void> dispose() async {
    await _cancelSubscriptions();
    await _projectsMetricsSubject.close();
  }
}
