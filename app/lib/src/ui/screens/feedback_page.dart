import 'package:flutter/material.dart';

import '../../core/feedback_models.dart';
import '../../core/ffi.dart';
import '../../l10n/strings.dart';
import '../theme.dart';

/// 反馈只在本页内存保存；调用方须在锁定或云会话变化时撤销 canContinue。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({
    super.key,
    required this.newId,
    required this.submit,
    required this.list,
    required this.get,
    required this.canContinue,
    this.accountId,
  });

  final Future<String> Function() newId;
  final Future<FeedbackDetail> Function(FeedbackSubmission) submit;
  final Future<FeedbackPageResult> Function(int? before) list;
  final Future<FeedbackDetail> Function(String id) get;
  final bool Function() canContinue;
  final String? accountId;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

enum _View { write, history, detail }

class _FeedbackPageState extends State<FeedbackPage> {
  final _form = GlobalKey<FormState>();
  final _content = TextEditingController();
  final _contact = TextEditingController();
  _View _view = _View.write;
  FeedbackCategory _category = FeedbackCategory.bug;
  bool _consent = false;
  bool _ended = false;
  bool _sending = false;
  bool _confirmDiscard = false;
  FeedbackSubmission? _pending;
  FeedbackDetail? _sent;
  String? _submitError;
  int _submitRequest = 0;

  List<FeedbackSummary> _items = const [];
  int? _nextBefore;
  int? _listBefore;
  bool _historyLoaded = false;
  bool _listing = false;
  String? _listError;
  int _listRequest = 0;

  FeedbackDetail? _detail;
  String? _detailId;
  bool _getting = false;
  String? _detailError;
  int _detailRequest = 0;

  // 撤销后本实例永不恢复，避免重新解锁时复活旧账户的结果。
  void _forget() {
    _ended = true;
    _submitRequest++;
    _listRequest++;
    _detailRequest++;
    _pending = null;
    _sent = null;
    _items = const [];
    _nextBefore = null;
    _detail = null;
    _detailId = null;
    _submitError = _listError = _detailError = null;
    _sending = _listing = _getting = false;
    _consent = false;
    _content.clear();
    _contact.clear();
  }

  bool _active({bool notify = true}) {
    if (!mounted || _ended) return false;
    if (widget.canContinue()) return true;
    if (notify) {
      setState(_forget);
    } else {
      _forget();
    }
    return false;
  }

  bool _acceptSubmit(int request) => _active() && request == _submitRequest;
  bool _acceptList(int request) => _active() && request == _listRequest;
  bool _acceptDetail(int request) => _active() && request == _detailRequest;

  @override
  void dispose() {
    _ended = true;
    _pending = null;
    _sent = null;
    _detail = null;
    _items = const [];
    _content.dispose();
    _contact.dispose();
    super.dispose();
  }

  String _message(Object error) {
    // 不展示异常 message：依赖错误可能含地址、服务端文本或诊断内容。
    final code = error is CoreException ? error.code : null;
    final source = switch (code) {
      'network' || 'timeout' => AppStrings.feedbackNetworkError,
      'unauthorized' => AppStrings.feedbackSessionExpired,
      'locked' || 'session_expired' => AppStrings.feedbackLocked,
      'not_connected' => AppStrings.feedbackNotConnected,
      'privacy_required' => AppStrings.feedbackPrivacyRequired,
      'feedback_unavailable' => AppStrings.feedbackUnsupported,
      'forbidden' ||
      'device_not_approved' ||
      'device_pending' ||
      'device_revoked' => AppStrings.feedbackForbidden,
      'invalid_input' ||
      'bad_request' ||
      'unprocessable_entity' => AppStrings.feedbackInvalid,
      'conflict' => AppStrings.feedbackDuplicate,
      'not_found' => AppStrings.feedbackNotFound,
      'rate_limited' => AppStrings.feedbackRateLimited,
      'unavailable' || 'service_unavailable' => AppStrings.feedbackUnavailable,
      _ => AppStrings.feedbackGenericError,
    };
    return context.tr(source);
  }

  Future<void> _send() async {
    if (!_active() || _sending) return;
    if (_pending == null && (!_consent || !_form.currentState!.validate())) {
      return;
    }
    // 在等待 ID 前冻结快照；任何不确定结果都只能重放这个不可变请求。
    final content = _content.text.trim();
    final contact = _contact.text.trim();
    final category = _category;
    final request = ++_submitRequest;
    setState(() {
      _sending = true;
      _submitError = null;
      _confirmDiscard = false;
    });
    try {
      var submission = _pending;
      if (submission == null) {
        if (!_acceptSubmit(request)) return;
        final id = await widget.newId();
        if (!_acceptSubmit(request)) return;
        submission = FeedbackSubmission(
          id: id,
          category: category,
          content: content,
          contact: contact.isEmpty ? null : contact,
        );
        _pending = submission;
      }
      if (!_acceptSubmit(request)) return;
      final result = await widget.submit(submission);
      if (!_acceptSubmit(request)) return;
      setState(() {
        _sending = false;
        _pending = null;
        _sent = result;
        _historyLoaded = false;
        // 先前的历史请求不应覆盖成功提交后的刷新。
        _listRequest++;
        _listing = false;
        _consent = false;
        _content.clear();
        _contact.clear();
      });
      if (_view == _View.history) _loadHistory();
    } catch (error) {
      if (!_acceptSubmit(request)) return;
      setState(() {
        _sending = false;
        _submitError = _message(error);
      });
    }
  }

  void _write() {
    if (!_active()) return;
    setState(() {
      _view = _View.write;
      _detailRequest++;
      _detail = null;
      _detailId = null;
      _getting = false;
      _detailError = null;
    });
  }

  void _history() {
    if (!_active()) return;
    setState(() {
      _view = _View.history;
      _detailRequest++;
      _detail = null;
      _detailId = null;
      _getting = false;
      _detailError = null;
    });
    if (!_historyLoaded && !_listing) _loadHistory();
  }

  Future<void> _loadHistory({int? before}) async {
    if (!_active()) return;
    final request = ++_listRequest;
    setState(() {
      _listing = true;
      _listBefore = before;
      _listError = null;
    });
    try {
      if (!_acceptList(request)) return;
      final page = await widget.list(before);
      if (!_acceptList(request)) return;
      setState(() {
        final existing = before == null ? <FeedbackSummary>[] : _items;
        final seen = existing.map((item) => item.id).toSet();
        _items = [
          ...existing,
          for (final item in page.items)
            if (seen.add(item.id)) item,
        ];
        _nextBefore = page.nextBefore == before ? null : page.nextBefore;
        _historyLoaded = true;
        _listing = false;
      });
    } catch (error) {
      if (!_acceptList(request)) return;
      setState(() {
        _listing = false;
        _listError = _message(error);
      });
    }
  }

  Future<void> _openDetail(String id) async {
    if (!_active()) return;
    final request = ++_detailRequest;
    setState(() {
      _view = _View.detail;
      _detailId = id;
      _detail = null;
      _getting = true;
      _detailError = null;
    });
    try {
      if (!_acceptDetail(request)) return;
      final detail = await widget.get(id);
      if (!_acceptDetail(request)) return;
      setState(() {
        _detail = detail;
        _getting = false;
      });
    } catch (error) {
      if (!_acceptDetail(request)) return;
      setState(() {
        _getting = false;
        _detailError = _message(error);
      });
    }
  }

  void _resetDraft() {
    if (!_active() || _sending) return;
    setState(() {
      _submitRequest++;
      _pending = null;
      _sent = null;
      _submitError = null;
      _confirmDiscard = false;
      _category = FeedbackCategory.bug;
      _consent = false;
      // Form.reset 可能恢复上次构建的 initialValue，必须在它之后清空控制器。
      _form.currentState?.reset();
      _content.clear();
      _contact.clear();
    });
  }

  void _close() {
    if (!mounted) return;
    setState(_forget);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final active = _active(notify: false);
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && !_ended) _forget();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            key: const Key('feedback-close'),
            tooltip: context.tr(AppStrings.feedbackClose),
            onPressed: _close,
            icon: const Icon(Icons.close),
          ),
          title: Text(context.tr(AppStrings.feedback), style: context.text.headlineSmall),
          actions: [
            if (active && _view != _View.write)
              IconButton(
                key: const Key('feedback-refresh'),
                tooltip: context.tr(AppStrings.refreshAction),
                onPressed: () {
                  if (_view == _View.detail && _detailId != null) {
                    _openDetail(_detailId!);
                  } else {
                    _loadHistory();
                  }
                },
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        body: !active
            ? Center(child: Text(context.tr(AppStrings.feedbackExpired)))
            : SafeArea(
                child: SingleChildScrollView(
                  key: const Key('feedback-scroll'),
                  padding: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _privacy(),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ChoiceChip(
                                key: const Key('feedback-write-tab'),
                                label: Text(context.tr(AppStrings.feedbackWriteTab)),
                                selected: _view == _View.write,
                                onSelected: (_) => _write(),
                              ),
                              ChoiceChip(
                                key: const Key('feedback-history-tab'),
                                label: Text(context.tr(AppStrings.feedbackHistoryTab)),
                                selected: _view != _View.write,
                                onSelected: (_) => _history(),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          switch (_view) {
                            _View.write => _editor(),
                            _View.history => _historyPane(),
                            _View.detail => _detailPane(),
                          },
                          const SizedBox(height: 24),
                          Text(
                            context.tr(AppStrings.feedbackDraftNotice),
                            style: context.text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _privacy() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: context.zo.accentSoft,
      borderRadius: BorderRadius.circular(Zo.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.tr(AppStrings.feedbackConsentTitle), style: context.text.titleMedium),
        const SizedBox(height: 8),
        Text(
          '${context.tr(AppStrings.feedbackConsentBody)}'
          '${context.tr(AppStrings.feedbackNoSecrets)}'
          '${context.tr(AppStrings.feedbackNoAutoAttach)}',
        ),
      ],
    ),
  );

  Widget _editor() {
    if (_sent case final detail?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.tr(AppStrings.feedbackSubmitted), style: context.text.titleLarge),
          const SizedBox(height: 16),
          _detailContent(detail),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _resetDraft,
            child: Text(context.tr(AppStrings.feedbackWriteAnother)),
          ),
        ],
      );
    }
    final frozen = _sending || _pending != null;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<FeedbackCategory>(
            key: ValueKey('feedback-category-${_category.name}'),
            initialValue: _category,
            isExpanded: true,
            decoration: InputDecoration(labelText: context.tr(AppStrings.feedbackCategory)),
            items: [
              for (final category in FeedbackCategory.values)
                DropdownMenuItem(value: category, child: Text(category.label(context))),
            ],
            onChanged: frozen
                ? null
                : (value) {
                    if (_active() && value != null) {
                      setState(() => _category = value);
                    }
                  },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('feedback-content'),
            controller: _content,
            readOnly: frozen,
            minLines: 5,
            maxLines: 10,
            decoration: InputDecoration(
              labelText: context.tr(AppStrings.feedbackBody),
              alignLabelWithHint: true,
              hintText: context.tr(AppStrings.feedbackBodyHint),
              counterText: '${_content.text.trim().length} / 4000 UTF-16',
            ),
            validator: (value) {
              final text = (value ?? '').trim();
              if (text.isEmpty) return context.tr(AppStrings.feedbackBodyRequired);
              if (text.length > 4000) return context.tr(AppStrings.feedbackBodyTooLong);
              return null;
            },
            onChanged: (_) {
              if (_active()) setState(() {});
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('feedback-contact'),
            controller: _contact,
            readOnly: frozen,
            decoration: InputDecoration(
              labelText: context.tr(AppStrings.feedbackContact),
              counterText: '${_contact.text.trim().length} / 200 UTF-16',
            ),
            validator: (value) => (value ?? '').trim().length > 200
                ? context.tr(AppStrings.feedbackContactTooLong)
                : null,
            onChanged: (_) {
              if (_active()) setState(() {});
            },
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const Key('feedback-consent'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(context.tr(AppStrings.feedbackConsentAck)),
            value: _consent,
            onChanged: frozen
                ? null
                : (value) {
                    if (_active()) setState(() => _consent = value ?? false);
                  },
          ),
          if (!_consent)
            Text(context.tr(AppStrings.feedbackConsentRequired), style: context.text.bodySmall),
          if (_submitError != null) _error(_submitError!),
          if (_pending != null && !_sending) ...[
            const SizedBox(height: 12),
            Text(context.tr(AppStrings.feedbackUnconfirmed)),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                key: const Key('feedback-submit'),
                onPressed: _sending || (!_consent && _pending == null)
                    ? null
                    : _send,
                child: Text(context.tr(
                  _sending
                      ? AppStrings.feedbackSubmitting
                      : _pending != null
                          ? AppStrings.feedbackRetryAsIs
                          : AppStrings.feedbackSubmit,
                )),
              ),
              if (_pending != null)
                TextButton(
                  key: const Key('feedback-abandon'),
                  onPressed: _sending
                      ? null
                      : () {
                          if (_active()) {
                            setState(() => _confirmDiscard = true);
                          }
                        },
                  child: Text(context.tr(AppStrings.feedbackDiscard)),
                )
              else
                TextButton(
                  onPressed: _sending ? null : _resetDraft,
                  child: Text(context.tr(AppStrings.feedbackClearDraft)),
                ),
            ],
          ),
          if (_confirmDiscard) ...[
            const SizedBox(height: 12),
            Text(context.tr(AppStrings.feedbackDiscardWarning)),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: _history,
                  child: Text(context.tr(AppStrings.feedbackCheckHistoryFirst)),
                ),
                OutlinedButton(
                  key: const Key('feedback-confirm-abandon'),
                  onPressed: _resetDraft,
                  child: Text(context.tr(AppStrings.feedbackConfirmDiscard)),
                ),
                TextButton(
                  onPressed: () {
                    if (_active()) setState(() => _confirmDiscard = false);
                  },
                  child: Text(context.tr(AppStrings.feedbackCancelDiscard)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _historyPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(context.tr(AppStrings.feedbackHistoryTab), style: context.text.titleLarge),
      const SizedBox(height: 12),
      if (_listing) const LinearProgressIndicator(),
      if (_listError != null) ...[
        _error(_listError!),
        TextButton(
          onPressed: _listing ? null : () => _loadHistory(before: _listBefore),
          child: Text(context.tr(AppStrings.feedbackRetryHistory)),
        ),
      ],
      if (_historyLoaded && _items.isEmpty && !_listing)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(context.tr(AppStrings.feedbackHistoryEmpty)),
        ),
      for (final item in _items)
        ListTile(
          key: ValueKey('feedback-item-${item.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text(
            '${item.category.label(context)} · ${item.status.label(context)}',
          ),
          subtitle: Text(_time(item.createdAt)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openDetail(item.id),
        ),
      if (_nextBefore != null)
        OutlinedButton(
          key: const Key('feedback-more'),
          onPressed: _listing ? null : () => _loadHistory(before: _nextBefore),
          child: Text(context.tr(AppStrings.feedbackLoadEarlier)),
        ),
    ],
  );

  Widget _detailPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('feedback-back-history'),
          onPressed: _history,
          icon: const Icon(Icons.arrow_back),
          label: Text(context.tr(AppStrings.feedbackBackToHistory)),
        ),
      ),
      if (_getting) const LinearProgressIndicator(),
      if (_detailError != null) ...[
        _error(_detailError!),
        TextButton(
          onPressed: () => _openDetail(_detailId!),
          child: Text(context.tr(AppStrings.feedbackRetryDetail)),
        ),
      ],
      if (_detail case final detail?) _detailContent(detail),
    ],
  );

  Widget _detailContent(FeedbackDetail detail) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '${detail.summary.category.label(context)} · ${detail.summary.status.label(context)}',
        style: context.text.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(
        context.trf(AppStrings.feedbackSubmittedAt, {'time': _time(detail.summary.createdAt)}),
        style: context.text.bodySmall,
      ),
      const SizedBox(height: 8),
      SelectableText(
        context.trf(AppStrings.feedbackIdLabel, {'id': detail.summary.id}),
        style: context.text.bodySmall,
      ),
      if (widget.accountId != null)
        SelectableText(
          context.trf(AppStrings.feedbackAccountLabel, {'id': widget.accountId}),
          style: context.text.bodySmall,
        ),
      const SizedBox(height: 16),
      Text(context.tr(AppStrings.feedbackSubmittedBody), style: context.text.titleMedium),
      const SizedBox(height: 8),
      // Text 不解析 HTML、Markdown 或链接，客服回复同样保持纯文本。
      Text(detail.content),
      if (detail.contact case final contact?) ...[
        const SizedBox(height: 16),
        Text(context.tr(AppStrings.feedbackContactLabel), style: context.text.titleMedium),
        const SizedBox(height: 8),
        Text(contact),
      ],
      const SizedBox(height: 24),
      const Divider(),
      const SizedBox(height: 16),
      Text(context.tr(AppStrings.feedbackLatestReply), style: context.text.titleMedium),
      const SizedBox(height: 8),
      Text(detail.reply?.isNotEmpty == true ? detail.reply! : context.tr(AppStrings.feedbackNoReply)),
    ],
  );

  Widget _error(String message) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(
      message,
      style: context.text.bodyMedium?.copyWith(color: context.zo.danger),
    ),
  );

  String _time(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    );
    return '${date.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';
  }
}
