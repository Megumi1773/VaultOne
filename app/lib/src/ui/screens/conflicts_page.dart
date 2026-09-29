import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/conflict_models.dart';
import '../../core/ffi.dart';
import '../theme.dart';
import '../widgets/controls.dart';

/// 冲突处理只通过注入回调访问内核；解决成功表示本地入队，不代表远端已接受。
class ConflictsPage extends StatefulWidget {
  const ConflictsPage({
    super.key,
    required this.listConflicts,
    required this.getConflict,
    required this.refreshConflict,
    required this.resolveConflict,
    required this.onResolved,
  });

  final Future<List<ConflictDetail>> Function(bool includeHistory)
  listConflicts;
  final Future<ConflictDetail> Function(String id) getConflict;
  final Future<ConflictDetail> Function(String id) refreshConflict;
  final Future<void> Function(String id, ConflictResolution resolution)
  resolveConflict;
  final VoidCallback onResolved;

  @override
  State<ConflictsPage> createState() => _ConflictsPageState();
}

class _ConflictsPageState extends State<ConflictsPage> {
  List<ConflictDetail> _items = const [];
  ConflictDetail? _selected;
  String? _selectedId;
  bool _refreshOnRetry = false;
  bool _history = false;
  bool _loading = true;
  bool _detailLoading = false;
  bool _resolving = false;
  bool _reveal = false;
  String? _error;
  String? _detailError;
  String? _notice;
  int _listRequest = 0;
  int _detailRequest = 0;
  final _choices = <ConflictField, ConflictSide>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _message(Object e) => e is CoreException ? e.message : '暂时无法读取冲突，请重试';

  Future<void> _load() async {
    final request = ++_listRequest;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.listConflicts(_history);
      if (!mounted || request != _listRequest) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _listRequest) return;
      setState(() {
        _error = _message(e);
        _loading = false;
      });
    }
  }

  Future<void> _select(String id, {bool refresh = false}) async {
    final request = ++_detailRequest;
    setState(() {
      _selected = null;
      _selectedId = id;
      _refreshOnRetry = refresh;
      _detailLoading = true;
      _detailError = null;
      _notice = null;
      _reveal = false;
      _choices.clear();
    });
    try {
      final detail = await (refresh
          ? widget.refreshConflict(id)
          : widget.getConflict(id));
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _selected = detail;
        _detailLoading = false;
        _items = [
          for (final item in _items)
            if (item.id == id) detail else item,
        ];
      });
    } catch (e) {
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _detailLoading = false;
        _detailError = _message(e);
      });
    }
  }

  Future<void> _resolve(ConflictResolution resolution) async {
    final detail = _selected;
    if (detail == null || _resolving || !resolution.isValidFor(detail)) return;
    setState(() {
      _resolving = true;
      _detailError = null;
      _notice = null;
    });
    try {
      await widget.resolveConflict(detail.id, resolution);
      if (!mounted) return;
      setState(() {
        _selected = detail.awaitingSync();
        _items = [
          for (final item in _items)
            if (item.id == detail.id) detail.awaitingSync() else item,
        ];
        _choices.clear();
        _reveal = false;
        _notice = '选择已保存到本机，等待同步。远端确认前仍可能产生新的冲突。';
      });
      widget.onResolved();
    } catch (e) {
      if (!mounted) return;
      if (e is CoreException && e.code == 'conflict_stale') {
        await _select(detail.id, refresh: true);
        if (mounted) setState(() => _notice = '候选已发生变化，请检查刷新后的版本并重新选择。');
      } else {
        setState(() => _detailError = _message(e));
      }
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('同步冲突')),
    body: LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 850;
        final detail =
            _selected != null || _detailLoading || _detailError != null;
        if (!wide) return detail ? _detailPane(back: true) : _listPane();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 290, child: _listPane()),
            VerticalDivider(width: 1, color: context.zo.border),
            Expanded(
              child: detail
                  ? _detailPane()
                  : const Center(child: Text('选择一个冲突查看双方版本')),
            ),
          ],
        );
      },
    ),
  );

  Widget _listPane() => Column(
    children: [
      SwitchListTile(
        title: const Text('显示历史记录'),
        value: _history,
        onChanged: _resolving
            ? null
            : (value) {
                setState(() => _history = value);
                _load();
              },
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _retry(_error!, _load)
            : _items.isEmpty
            ? Center(child: Text(_history ? '暂无冲突记录' : '没有待处理的冲突'))
            : ListView(
                children: [
                  for (final item in _items)
                    ListTile(
                      key: ValueKey('conflict-${item.id}'),
                      selected: _selected?.id == item.id,
                      title: Text(
                        item.local.data.title.isEmpty
                            ? '未命名条目'
                            : item.local.data.title,
                      ),
                      subtitle: Text(item.statusLabel),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _resolving ? null : () => _select(item.id),
                    ),
                ],
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: ZoButton(
          label: '刷新列表',
          variant: ZoButtonVariant.secondary,
          onPressed: _resolving || _loading ? null : _load,
        ),
      ),
    ],
  );

  Widget _retry(String message, VoidCallback onRetry) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 16),
          ZoButton(label: '重试', onPressed: onRetry),
        ],
      ),
    ),
  );

  Widget _detailPane({bool back = false}) {
    final detail = _selected;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (back)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _resolving
                    ? null
                    : () => setState(() {
                        _detailRequest++;
                        _selected = null;
                        _detailLoading = false;
                        _detailError = null;
                        _reveal = false;
                        _choices.clear();
                      }),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回冲突列表'),
              ),
            ),
          if (_detailLoading)
            const Center(child: CircularProgressIndicator())
          else if (detail == null)
            _retry(_detailError ?? '请选择一个冲突', () {
              if (_selectedId != null) {
                _select(_selectedId!, refresh: _refreshOnRetry);
              }
            })
          else ...[
            Text(detail.local.data.title, style: context.text.headlineSmall),
            const SizedBox(height: 8),
            Text(detail.statusLabel, style: context.text.titleMedium),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_notice!),
              ),
            if (_detailError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _detailError!,
                  style: TextStyle(color: context.zo.danger),
                ),
              ),
            if (detail.stale)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('候选已过期，不能提交旧选择。请先刷新候选。'),
              ),
            if (detail.state == ConflictState.resolutionPending)
              const Text('解决方案已在本地排队，等待同步。这里不表示已经同步成功。'),
            if (detail.state == ConflictState.resolved ||
                detail.state == ConflictState.superseded)
              const Text('历史记录，仅供查看，不能再次提交。'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ZoButton(
                  label: '刷新候选',
                  variant: ZoButtonVariant.secondary,
                  onPressed:
                      _resolving ||
                          detail.state == ConflictState.resolved ||
                          detail.state == ConflictState.superseded
                      ? null
                      : () => _select(detail.id, refresh: true),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _reveal = !_reveal),
                  icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
                  label: Text(_reveal ? '隐藏敏感内容' : '显示敏感内容'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (detail.wholeOnly) const Text('条目类型或解决方案存在冲突，只能整条保留一方。'),
            if (detail.canResolve) ...[
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  ZoButton(
                    label: '保留整条本地',
                    onPressed: _resolving
                        ? null
                        : () => _resolve(
                            const ConflictResolution.whole(ConflictSide.local),
                          ),
                  ),
                  ZoButton(
                    label: '保留整条远端',
                    variant: ZoButtonVariant.secondary,
                    onPressed: _resolving
                        ? null
                        : () => _resolve(
                            const ConflictResolution.whole(ConflictSide.remote),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('整条保留会采用该方的全部内容；下方可比较所有字段。'),
            ],
            const SizedBox(height: 20),
            for (final field in ConflictField.values.where(
              (f) => f != ConflictField.resolution,
            ))
              _comparison(detail, field),
            if (detail.canResolve &&
                !detail.wholeOnly &&
                detail.fields.isNotEmpty)
              ZoButton(
                key: const ValueKey('resolve-fields'),
                label: '提交逐字段选择（${_choices.length}/${detail.fields.length}）',
                loading: _resolving,
                onPressed:
                    _resolving ||
                        !ConflictResolution.fields(_choices).isValidFor(detail)
                    ? null
                    : () => _resolve(ConflictResolution.fields(_choices)),
              ),
          ],
        ],
      ),
    );
  }

  String _value(ConflictVersion version, ConflictField field) {
    if (field.sensitive && !_reveal) return '敏感内容已隐藏';
    final value = version.value(field);
    if (field == ConflictField.deleted) {
      return switch (value) {
        true => '已删除',
        false => '未删除',
        _ => '未知（旧基线未记录）',
      };
    }
    if (value == null) return '（空）';
    if (value is String) return value.isEmpty ? '（空）' : value;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  Widget _comparison(ConflictDetail detail, ConflictField field) {
    final conflict = detail.fields.contains(field);
    final selectable = conflict && detail.canResolve && !detail.wholeOnly;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ZoPanel(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${field.label}${conflict ? ' · 冲突' : ''}',
              style: context.text.titleMedium,
            ),
            if (detail.base != null) ...[
              const SizedBox(height: 8),
              Text('共同基础 · v${detail.base!.revision}'),
              Text(_value(detail.base!, field)),
            ],
            const SizedBox(height: 12),
            for (final side in ConflictSide.values) ...[
              Text(
                '${side == ConflictSide.local ? '本地' : '远端'} · v${(side == ConflictSide.local ? detail.local : detail.remote).revision}',
                style: context.text.labelLarge,
              ),
              const SizedBox(height: 4),
              SelectableText(
                _value(
                  side == ConflictSide.local ? detail.local : detail.remote,
                  field,
                ),
              ),
              if (selectable)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: ValueKey('choose-${field.name}-${side.name}'),
                    onPressed: _resolving
                        ? null
                        : () => setState(() => _choices[field] = side),
                    icon: Icon(
                      _choices[field] == side
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    label: Text(
                      '采用${side == ConflictSide.local ? '本地' : '远端'}${field.label}',
                    ),
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }
}
