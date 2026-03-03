import 'package:flutter/foundation.dart';

import '../repositories/agent_repository.dart';

/// Resolve post-login destination based on whether the user has any employees.
Future<String> resolvePostLoginDestination() async {
  final repository = AgentRepository();
  try {
    final page = await repository.getUserAgents(limit: 1, forceRefresh: true);
    final destination = page.agents.isEmpty ? '/rooms/team' : '/rooms';
    debugPrint(
      '[PostLoginNavigation] Resolved by API: employees=${page.agents.length}, destination=$destination',
    );
    return destination;
  } finally {
    repository.dispose();
  }
}
