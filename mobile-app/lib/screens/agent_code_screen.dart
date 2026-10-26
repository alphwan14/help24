import 'package:flutter/material.dart';

import '../services/agent_code_service.dart';
import '../theme/app_icons.dart';

/// "Who helped you join?" — Profile → Account.
///
/// Shows the agent this account is credited to, and lets a member add or
/// correct the code in their first 3 days (the server enforces the window;
/// this screen only explains it). Agents are paid per member they bring, so
/// the code is the member's way of saying thank you — and it is optional.
class AgentCodeScreen extends StatefulWidget {
  const AgentCodeScreen({super.key});

  @override
  State<AgentCodeScreen> createState() => _AgentCodeScreenState();
}

class _AgentCodeScreenState extends State<AgentCodeScreen> {
  AgentCredit? _credit;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final credit = await AgentCodeService.myCredit();
    if (!mounted) return;
    setState(() {
      _credit = credit;
      _failed = credit == null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final credit = _credit;
    return Scaffold(
      appBar: AppBar(title: const Text('Who helped you join?')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'If a Help24 agent helped you sign up, add their code so they are thanked for it. '
            "It's optional, and it doesn't change anything about your account.",
            style: text.bodyMedium,
          ),
          const SizedBox(height: 20),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
          else if (_failed) ...[
            Text("We couldn't check this just now.", style: text.bodyMedium),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(onPressed: _load, icon: const Icon(AppIcons.refresh), label: const Text('Try again')),
            ),
          ] else ...[
            if (credit!.credited)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(AppIcons.successFilled),
                title: Text(credit.agentName!),
                subtitle: Text('Agent code ${credit.code}'),
              ),
            if (credit.canChange) ...[
              const SizedBox(height: 8),
              AgentCodeForm(
                buttonLabel: credit.credited ? 'Change code' : 'Add code',
                onClaimed: (_) => _load(),
              ),
              if (credit.windowEndsAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  'You can add or change this until ${_day(credit.windowEndsAt!.toLocal())}.',
                  style: text.bodySmall,
                ),
              ],
            ] else if (!credit.credited)
              Text(
                'Agent codes can only be added in your first 3 days on Help24.',
                style: text.bodyMedium,
              ),
          ],
        ],
      ),
    );
  }

  static String _day(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${months[d.month - 1]}, $h:$m ${d.hour < 12 ? 'am' : 'pm'}';
  }
}

/// The code field and its button, shared by the screen and the sheet.
class AgentCodeForm extends StatefulWidget {
  final String buttonLabel;
  final String? initialCode;
  final ValueChanged<AgentClaimResult> onClaimed;

  const AgentCodeForm({super.key, required this.buttonLabel, required this.onClaimed, this.initialCode});

  @override
  State<AgentCodeForm> createState() => _AgentCodeFormState();
}

class _AgentCodeFormState extends State<AgentCodeForm> {
  late final TextEditingController _code = TextEditingController(text: widget.initialCode ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await AgentCodeService.claim(_code.text, AgentCodeMethod.code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.ok ? null : result.error;
    });
    if (result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(agentThanks(result))));
      widget.onClaimed(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _code,
          enabled: !_busy,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: 'Agent code',
            hintText: 'H24-7K3Q',
            errorText: _error,
            errorMaxLines: 3,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(widget.buttonLabel),
        ),
      ],
    );
  }
}

/// What a member is told after a code is accepted.
String agentThanks(AgentClaimResult r) {
  final who = r.agentName ?? 'Your agent';
  return switch (r.status) {
    'unchanged' => '$who is already credited for helping you join.',
    'changed' => 'Changed — $who is now credited for helping you join.',
    _ => 'Thanks — $who is credited for helping you join.',
  };
}

/// The one-time prompt for a new member: "Did someone help you join?"
class AgentCodeSheet extends StatelessWidget {
  const AgentCodeSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const AgentCodeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Did someone help you join?', style: text.titleMedium),
          const SizedBox(height: 6),
          Text(
            "If a Help24 agent signed you up, add their code so they're thanked for it. "
            'You can also do this later in Profile.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          AgentCodeForm(buttonLabel: 'Add code', onClaimed: (_) => Navigator.of(context).pop()),
          const SizedBox(height: 4),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('No one — skip')),
        ],
      ),
    );
  }
}
