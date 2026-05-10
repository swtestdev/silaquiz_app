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
  AnswerEditorDialog({
    super.key,
    required this.questionId,
    required this.questionNum,
    this.subtitle,
    required this.inputType,
    required this.options,
    required this.initialValue,
    required this.isEditable,
    required this.onPersist,
    this.roundUsesSharedListPool = false,
    int? Function(String option)? ownerQuestionIdForOption,
    /// When non-null (shared list rounds), list checkboxes rebuild when answers/ownership change elsewhere.
    this.answerPoolRevision,
    this.debounce = const Duration(milliseconds: 500),
  }) : ownerQuestionIdForOption = ownerQuestionIdForOption ?? _defaultListOwner;

  static int? _defaultListOwner(String _) => null;

  final int questionId;
  final int questionNum;
  final String? subtitle;
  final String inputType;
  final List<String> options;
  final String initialValue;
  final bool Function() isEditable;
  final Future<AnswerPersistStatus> Function(String newValue) onPersist;

  /// When [roundTimer] != 0 list mode: an option is blocked if it appears on another question.
  final bool roundUsesSharedListPool;
  final int? Function(String option) ownerQuestionIdForOption;
  final Listenable? answerPoolRevision;
  final Duration debounce;

  @override
  State<AnswerEditorDialog> createState() => _AnswerEditorDialogState();
}

class _AnswerEditorDialogState extends State<AnswerEditorDialog> {
  late final TextEditingController _textController;
  late final FocusNode _textFocusNode;
  String _radioValue = '';
  late Set<String> _listSelected;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  /// True while user-initiated or timer forced close is in progress — blocks focus recovery.
  bool _isClosingDialog = false;
  /// True only while closing — updated without [setState] so autosave never rebuilds the input subtree.
  late final ValueNotifier<bool> _inputLocked;
  /// "Saving…" / "Saved" / errors — isolated with [ValueListenableBuilder], not [setState].
  late final ValueNotifier<String> _statusLine;
  String _lastPersisted = '';
  /// Throttled one-shot re-focus when focus is lost unexpectedly (not on save/debounce).
  Timer? _refocusRecoveryTimer;
  static const _refocusThrottle = Duration(milliseconds: 200);

  @override
  void initState() {
    super.initState();
    _inputLocked = ValueNotifier<bool>(false);
    _statusLine = ValueNotifier<String>('');
    _lastPersisted = widget.initialValue;
    _textController = TextEditingController(text: widget.initialValue);
    _textFocusNode = FocusNode();
    _textFocusNode.addListener(_onTextFocusChanged);
    _radioValue = widget.initialValue;
    if (widget.inputType == 'radio' && _radioValue.isNotEmpty && !widget.options.contains(_radioValue)) {
      _radioValue = '';
    }
    _listSelected = _parseListValue(widget.initialValue);
    // Request focus once after first frame; do not use TextField.autofocus (avoids double request).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isClosingDialog) return;
      if (widget.inputType == 'text' && widget.isEditable()) {
        _textFocusNode.requestFocus();
      }
    });
    _pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      if (!widget.isEditable() && !_inputLocked.value && !_isClosingDialog) {
        unawaited(_onShouldClose());
      }
    });
  }

  void _onTextFocusChanged() {
    if (!mounted || widget.inputType != 'text') return;
    if (_textFocusNode.hasFocus) {
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
      if (_textFocusNode.hasFocus) return;
      _textFocusNode.requestFocus();
    });
  }

  Set<String> _parseListValue(String s) {
    return s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
  }

  @override
  void dispose() {
    _refocusRecoveryTimer?.cancel();
    _textFocusNode.removeListener(_onTextFocusChanged);
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _inputLocked.dispose();
    _statusLine.dispose();
    FocusManager.instance.primaryFocus?.unfocus();
    _textFocusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  String _listValueOrdered() {
    return widget.options.where((e) => _listSelected.contains(e)).join(',');
  }

  String _currentValueString() {
    switch (widget.inputType) {
      case 'radio':
        return _radioValue;
      case 'list':
        return _listValueOrdered();
      case 'text':
      default:
        return _textController.text;
    }
  }

  Future<void> _onShouldClose() async {
    if (!mounted || _isClosingDialog) return;
    _isClosingDialog = true;
    _refocusRecoveryTimer?.cancel();
    if (!mounted) return;
    _statusLine.value = 'Saving…';
    _inputLocked.value = true;
    if (widget.inputType == 'text') {
      _debounceTimer?.cancel();
    }
    await _doPersist(_currentValueString(), showStatus: false);
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
  }

  Future<AnswerPersistStatus> _doPersist(String value, {bool showStatus = true}) async {
    if (value == _lastPersisted) {
      if (showStatus) {
        _statusLine.value = 'Saved';
      }
      return AnswerPersistStatus.success;
    }
    // Status line only: no setState, no _ioLocked — keeps TextField/FocusNode stable during autosave.
    if (showStatus) {
      _statusLine.value = 'Saving…';
    }
    final st = await widget.onPersist(value);
    if (!mounted) return st;
    if (!showStatus) {
      switch (st) {
        case AnswerPersistStatus.success:
          _lastPersisted = value;
          break;
        default:
          break;
      }
      return st;
    }
    switch (st) {
      case AnswerPersistStatus.success:
        _statusLine.value = 'Saved';
        _lastPersisted = value;
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
        unawaited(_doPersist(_textController.text));
      }
    });
  }

  void _onRadioChanged(String? v) {
    final s = v ?? '';
    setState(() => _radioValue = s);
    unawaited(_doPersist(s));
  }

  void _onListToggle(String option, bool? select) {
    if (_inputLocked.value) return;
    final turnOn = select == true;
    // Shared pool: conflicts are prevented in UI (disabled tiles); no SnackBar.
    if (turnOn && widget.roundUsesSharedListPool) {
      final owner = widget.ownerQuestionIdForOption(option);
      if (owner != null && owner != widget.questionId) {
        return;
      }
    }
    final next = Set<String>.from(_listSelected);
    if (turnOn) {
      next.add(option);
    } else {
      next.remove(option);
    }
    final v = widget.options.where((e) => next.contains(e)).join(',');
    setState(() {
      _listSelected = next;
    });
    unawaited(_doPersist(v));
  }

  @override
  Widget build(BuildContext context) {
    // Intentionally no [setState] for save/status/lock: [_statusLine] and [_inputLocked] are notifiers.
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
            // Rebuilds input only when closing ([_inputLocked]), not on each debounced save.
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
            if (widget.inputType == 'text') {
              FocusManager.instance.primaryFocus?.unfocus();
              unawaited(_doPersist(_textController.text, showStatus: false).then((_) {
                if (!mounted) return;
                Navigator.of(context).pop();
              }));
            } else {
              FocusManager.instance.primaryFocus?.unfocus();
              Navigator.of(context).pop();
            }
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
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: widget.options
              .map(
                (o) => RadioListTile<String>(
                  title: Text(o, maxLines: 2, overflow: TextOverflow.ellipsis),
                  value: o,
                  groupValue: _radioValue.isNotEmpty && widget.options.contains(_radioValue) ? _radioValue : null,
                  onChanged: enabled
                      ? (v) {
                          if (v != null) {
                            _onRadioChanged(v);
                          }
                        }
                      : null,
                ),
              )
              .toList(),
        );
      case 'list':
        if (widget.options.isEmpty) {
          return const Text('No options available');
        }
        Widget listColumn() => Column(
              mainAxisSize: MainAxisSize.min,
              children: widget.options.map((o) {
                final isOn = _listSelected.contains(o);
                final int? owner =
                    widget.roundUsesSharedListPool ? widget.ownerQuestionIdForOption(o) : null;
                final usedElsewhere =
                    owner != null && owner != widget.questionId;
                final canToggle = enabled && (!usedElsewhere || isOn);
                final theme = Theme.of(context);
                final titleStyle = (usedElsewhere && !isOn)
                    ? theme.textTheme.bodyLarge?.copyWith(color: theme.disabledColor)
                    : null;
                return CheckboxListTile(
                  value: isOn,
                  onChanged: canToggle
                      ? (v) {
                          _onListToggle(o, v);
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
                );
              }).toList(),
            );
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
        return TextField(
          controller: _textController,
          focusNode: _textFocusNode,
          enabled: enabled,
          minLines: 1,
          maxLines: 6,
          maxLength: 200,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          onChanged: (_) => _scheduleTextPersist(),
        );
    }
  }
}
