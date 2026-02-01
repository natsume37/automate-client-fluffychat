library;

import 'agent_template.dart';

class HireResult {
  final UnifiedCreateAgentResponse response;
  final String displayName;

  const HireResult({
    required this.response,
    required this.displayName,
  });
}
