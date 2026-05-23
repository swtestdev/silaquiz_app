import 'dart:async';
import 'package:flutter/material.dart';

/// Result of persisting an answer to the server / local cache.
enum AnswerPersistStatus {
  success,
  failed,
  conflict,
  offline,
}

class AnswerEditorDialog extends StatefulWidget {
  /// Max characters per text answer slot (shown in editor).
  static const int textSlotMaxLength = 50;

  AnswerEditorDialog({
    super.key,
    required this.questionId,
    required this.questionNum,
    this.subtitle,
    required this.inputType,
    required this.options,
    required this.slotCount,
    required this.initialSlotValues,
    required this.onPersistSlots,
    required this.isEditable,
    this.roundUsesSharedListPool = false,
    int? Function(String option)? ownerQuestionIdForOption,
    /// When non-null (shared list rounds), list checkboxes rebuild when answers/ownership change elsewhere.
    this.answerPoolRevision,
    this.debounce = const Duration(milliseconds: 500),
  })  : assert(slotCount >= 1 && slotCount <= 4),
        assert(initialSlotValues.length == slotCount),
        ownerQuestionIdForOption = ownerQuestionIdForOption ?? _defaultListOwner;

  static int? _defaultListOwner(String _) => null;

  final int questionId;
  final int questionNum;
  final String? subtitle;
  final String inputType;
  final List<String> options;
  /// How many answer cells are active (matches nonempty game answer1..answer4).
  final int slotCount;
  final List<String> initialSlotValues;
  final Future<AnswerPersistStatus> Function(List<String> slots) onPersistSlots;
  final bool Function() isEditable;

  /// When [roundTimer] != 0 list mode: an option is blocked if it appears on another question.
  final bool roundUsesSharedListPool;
  final int? Function(String option) ownerQuestionIdForOption;
  final Listenable? answerPoolRevision;
  final Duration debounce;

  @override
  State<AnswerEditorDialog> createState() => _AnswerEditorDialogState();
}

class _AnswerEditorDialogState extends State<AnswerEditorDialog> {
  late final List<TextEditingController> _textCtrls;
  late final List<FocusNode> _textFocusNodes;
  late List<String> _radioVals;
  late List<Set<String>> _listSets;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  bool _isClosingDialog = false;
  late final ValueNotifier<bool> _inputLocked;
  late final ValueNotifier<String> _statusLine;
  late List<String> _lastPersistedSlots;
  Timer? _refocusRecoveryTimer;
  static const _refocusThrottle = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _inputLocked = ValueNotifier<bool>(false);
    _statusLine = ValueNotifier<String>('');

    final init = widget.initialSlotValues;

    _textCtrls = List.generate(
      widget.slotCount,
      (i) => TextEditingController(text: i < init.length ? init[i] : ''),
    );
    _textFocusNodes = List.generate(widget.slotCount, (_) => FocusNode());
    _radioVals = List<String>.generate(widget.slotCount, (i) {
      if (widget.inputType != 'radio') {
        return '';
      }
      final v = i < init.length ? init[i].trim() : '';
      if (v.isNotEmpty && !widget.options.contains(v)) {
        return '';
      }
      return v;
    });
    _listSets = List<Set<String>>.generate(widget.slotCount, (i) {
      if (widget.inputType != 'list') {
        return <String>{};
      }
      final s = i < init.length ? init[i] : '';
      return _parseListValue(s);
    });

    if (widget.inputType == 'text') {
      for (final n in _textFocusNodes) {
        n.addListener(_onAnyTextSlotFocusChanged);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isClosingDialog) return;
      if (widget.inputType == 'text' && widget.isEditable()) {
        _textFocusNodes[0].requestFocus();
      }
    });

    _lastPersistedSlots = List.from(_collectSlotsRaw());

    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      if (!widget.isEditable() && !_inputLocked.value && !_isClosingDialog) {
        unawaited(_onShouldClose());
      }
    });
  }

  /// Recover focus after an accidental unfocus — but never steal focus from another slot.
  void _onAnyTextSlotFocusChanged() {
    if (!mounted || widget.inputType != 'text') return;
    final anyFocused = _textFocusNodes.any((n) => n.hasFocus);
    if (anyFocused) {
      _refocusRecoveryTimer?.cancel();
      _refocusRecoveryTimer = null;
      return;
    }
    if (_isClosingDialog || _inputLocked.value) return;
    if (!widget.isEditable()) return;
    _refocusRecoveryTimer?.cancel();
    _refocusRecoveryTimer = Timer(_refocusThrottle, () {
      _refocusRecoveryTimer = null;
      if (!mounted || _isClosingDialog || _inputLocked.value) return;
      if (widget.inputType != 'text' || !widget.isEditable()) return;
      if (_textFocusNodes.any((n) => n.hasFocus)) return;
      _textFocusNodes[0].requestFocus();
    });
  }

  Set<String> _parseListValue(String s) {
    return s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  String _joinList(Set<String> sel) {
    return widget.options.where((e) => sel.contains(e)).join(',');
  }

  List<String> _collectSlotsRaw() {
    switch (widget.inputType) {
      case 'radio':
        return List<String>.from(_radioVals);
      case 'list':
        return List<String>.generate(widget.slotCount, (i) => _joinList(_listSets[i]));
      case 'text':
      default:
        return List<String>.generate(widget.slotCount, (i) => _textCtrls[i].text);
    }
  }

  @override
  void dispose() {
    _refocusRecoveryTimer?.cancel();
    if (widget.inputType == 'text' && _textFocusNodes.isNotEmpty) {
      for (final n in _textFocusNodes) {
        n.removeListener(_onAnyTextSlotFocusChanged);
      }
    }
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _inputLocked.dispose();
    _statusLine.dispose();
    FocusManager.instance.primaryFocus?.unfocus();
    for (final n in _textFocusNodes) {
      n.dispose();
    }
    for (final c in _textCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  bool _slotsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  Future<void> _onShouldClose() async {
    if (!mounted || _isClosingDialog) return;
    _isClosingDialog = true;
    _refocusRecoveryTimer?.cancel();
    if (!mounted) return;
    _statusLine.value = 'Saving…';
    _inputLocked.value = true;
    _debounceTimer?.cancel();
    await _doPersist(_collectSlotsRaw(), showStatus: false);
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
  }

  Future<AnswerPersistStatus> _doPersist(List<String> slots, {bool showStatus = true}) async {
    if (_slotsEqual(slots, _lastPersistedSlots)) {
      if (showStatus) {
        _statusLine.value = 'Saved';
      }
      return AnswerPersistStatus.success;
    }
    if (showStatus) {
      _statusLine.value = 'Saving…';
    }
    final st = await widget.onPersistSlots(slots);
    if (!mounted) return st;
    if (!showStatus) {
      switch (st) {
        case AnswerPersistStatus.success:
          _lastPersistedSlots = List.from(slots);
          break;
        default:
          break;
      }
      return st;
    }
    switch (st) {
      case AnswerPersistStatus.success:
        _statusLine.value = 'Saved';
        _lastPersistedSlots = List.from(slots);
        break;
      case AnswerPersistStatus.offline:
        _statusLine.value = 'Offline';
        break;
      case AnswerPersistStatus.conflict:
        _statusLine.value = 'Could not save (conflict)';
        break;
      case AnswerPersistStatus.failed:
        _statusLine.value = 'Save failed';
        break;
    }
    return st;
  }

  void _scheduleTextPersist() {
    if (_inputLocked.value) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, () {
      if (mounted) {
        unawaited(_doPersist(_collectSlotsRaw()));
      }
    });
  }

  void _onRadioChanged(int slotIndex, String? v) {
    final s = v ?? '';
    setState(() => _radioVals[slotIndex] = s);
    unawaited(_doPersist(_collectSlotsRaw()));
  }

  void _onListToggle(int slotIndex, String option, bool? select) {
    if (_inputLocked.value) return;
    final turnOn = select == true;
    if (turnOn && widget.roundUsesSharedListPool) {
      final owner = widget.ownerQuestionIdForOption(option);
      if (owner != null && owner != widget.questionId) {
        return;
      }
    }
    final next = Set<String>.from(_listSets[slotIndex]);
    if (turnOn) {
      next.add(option);
    } else {
      next.remove(option);
    }
    setState(() {
      _listSets[slotIndex] = next;
    });
    unawaited(_doPersist(_collectSlotsRaw()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.subtitle != null && widget.subtitle!.isNotEmpty
            ? 'Question ${widget.questionNum} — ${widget.subtitle}'
            : 'Question ${widget.questionNum}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: _statusLine,
              builder: (context, line, __) {
                if (line.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    line,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: _inputLocked,
              builder: (context, inputLocked, __) {
                final enabled = widget.isEditable() && !inputLocked;
                return _buildBody(enabled, context);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_isClosingDialog) return;
            _isClosingDialog = true;
            _refocusRecoveryTimer?.cancel();
            _debounceTimer?.cancel();
            _inputLocked.value = true;
            FocusManager.instance.primaryFocus?.unfocus();
            unawaited(_doPersist(_collectSlotsRaw(), showStatus: false).then((_) {
              if (!mounted) return;
              Navigator.of(context).pop();
            }));
          },
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildBody(bool enabled, BuildContext context) {
    switch (widget.inputType) {
      case 'radio':
        if (widget.options.isEmpty) {
          return const Text('No options available');
        }
        final tiles = <Widget>[];
        for (var s = 0; s < widget.slotCount; s++) {
          if (widget.slotCount > 1) {
            tiles.add(
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  'Answer ${s + 1}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            );
          }
          for (final o in widget.options) {
            final gv = _radioVals[s].isNotEmpty && widget.options.contains(_radioVals[s]) ? _radioVals[s] : null;
            tiles.add(
              RadioListTile<String>(
                title: Text(o, maxLines: 2, overflow: TextOverflow.ellipsis),
                value: o,
                groupValue: gv,
                onChanged: enabled
                    ? (v) {
                        if (v != null) {
                          _onRadioChanged(s, v);
                        }
                      }
                    : null,
              ),
            );
          }
        }
        return Column(mainAxisSize: MainAxisSize.min, children: tiles);
      case 'list':
        if (widget.options.isEmpty) {
          return const Text('No options available');
        }
        Widget listColumn() {
          final cols = <Widget>[];
          for (var s = 0; s < widget.slotCount; s++) {
            if (widget.slotCount > 1) {
              cols.add(
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Answer ${s + 1}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              );
            }
            for (final o in widget.options) {
              final isOn = _listSets[s].contains(o);
              final int? owner = widget.roundUsesSharedListPool ? widget.ownerQuestionIdForOption(o) : null;
              final usedElsewhere = owner != null && owner != widget.questionId;
              final canToggle = enabled && (!usedElsewhere || isOn);
              final theme = Theme.of(context);
              final titleStyle = (usedElsewhere && !isOn)
                  ? theme.textTheme.bodyLarge?.copyWith(color: theme.disabledColor)
                  : null;
              cols.add(
                CheckboxListTile(
                  value: isOn,
                  onChanged: canToggle
                      ? (v) {
                          _onListToggle(s, o, v);
                        }
                      : null,
                  title: Text(
                    o,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                  subtitle: (usedElsewhere && !isOn)
                      ? Text(
                          'Used in another question',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.disabledColor,
                          ),
                        )
                      : null,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              );
            }
          }
          return Column(mainAxisSize: MainAxisSize.min, children: cols);
        }

        final rev = widget.answerPoolRevision;
        if (rev != null) {
          return ListenableBuilder(
            listenable: rev,
            builder: (_, __) => listColumn(),
          );
        }
        return listColumn();
      case 'text':
      default:
        if (widget.slotCount == 1) {
          return TextField(
            controller: _textCtrls[0],
            focusNode: _textFocusNodes[0],
            enabled: enabled,
            minLines: 1,
            maxLines: 6,
            maxLength: AnswerEditorDialog.textSlotMaxLength,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onChanged: (_) => _scheduleTextPersist(),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(widget.slotCount, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _textCtrls[i],
                focusNode: _textFocusNodes[i],
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                maxLength: AnswerEditorDialog.textSlotMaxLength,
                decoration: InputDecoration(
                  labelText: 'Answer ${i + 1}',
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onChanged: (_) => _scheduleTextPersist(),
              ),
            );
          }),
        );
    }
  }
}
