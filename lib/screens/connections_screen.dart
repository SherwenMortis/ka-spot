import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../services/kaspot_service.dart';
import '../widgets/kaspot_avatar.dart';
import 'circle_chat_screen.dart';

// ---------------------------------------------------------------------------
// ConnectionsScreen — redesigned Circle tab
// ---------------------------------------------------------------------------

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  // ── Data state ─────────────────────────────────────────────────────────
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _people = [];
  List<Map<String, dynamic>> _requests = [];
  Map<String, bool> _sharing = {};
  Map<String, bool> _incomingSharing = {};
  String? _error;

  // ── Search ─────────────────────────────────────────────────────────────
  bool _searchActive = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  // ── Timers ─────────────────────────────────────────────────────────────
  Timer? _errorTimer;
  Timer? _refreshTimer;

  // ── Derived lists ──────────────────────────────────────────────────────
  List<Map<String, dynamic>> get _filteredPeople {
    if (_searchQuery.isEmpty) return _people;
    final q = _searchQuery.toLowerCase();
    return _people.where((p) {
      final name = (p['display_name'] as String? ?? '').toLowerCase();
      return name.contains(q);
    }).toList();
  }

  List<Map<String, dynamic>> get _incomingRequests {
    final myId = KaSpotService.userId;
    return _requests
        .where((r) => r['recipient_id'] == myId && r['status'] == 'pending')
        .toList();
  }

  List<Map<String, dynamic>> get _sentInvitations {
    final myId = KaSpotService.userId;
    return _requests
        .where((r) =>
            r['requester_id'] == myId &&
            (r['status'] == 'pending' || r['status'] == 'rejected'))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(KaSpotService.loadUnreadCounts());
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _busy || _loading) return;
      _load(silent: true);
    });
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    _refreshTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── Data loading ────────────────────────────────────────────────────────

  Future<void> _load({bool silent = false}) async {
    if (mounted && !silent) setState(() => _loading = true);
    try {
      final result = await Future.wait([
        KaSpotService.connections(),
        KaSpotService.requests(),
        KaSpotService.sharingGrants(),
        KaSpotService.incomingSharingStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _people = result[0] as List<Map<String, dynamic>>;
        _requests = result[1] as List<Map<String, dynamic>>;
        _sharing = {
          for (final row in result[2] as List<Map<String, dynamic>>)
            row['recipient_id'] as String: row['is_enabled'] as bool,
        };
        _incomingSharing = result[3] as Map<String, bool>;
        if (!silent) _error = null;
      });
    } catch (e) {
      if (mounted && !silent) _setError(e.toString());
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  void _setError(String? msg) {
    _errorTimer?.cancel();
    if (!mounted) return;
    setState(() => _error = msg);
    if (msg != null && msg.isNotEmpty) {
      _errorTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _error = null);
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    _errorTimer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
      if (mounted) _notify(success);
    } catch (e) {
      if (mounted) _setError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Future<void> _setSharing(String recipientId, bool enabled) async {
    if (!enabled) {
      await KaSpotService.setSharing(recipientId, false);
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Turn on device location services before sharing.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw Exception('Location permission was not granted. Sharing remains off.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.high),
    );
    await KaSpotService.setSharing(recipientId, true);
    await KaSpotService.upsertOwnLocation(position);
  }

  // ── Search helpers ──────────────────────────────────────────────────────

  void _openSearch() {
    setState(() {
      _searchActive = true;
      _searchQuery = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searchActive = false;
      _searchQuery = '';
      _searchController.clear();
    });
    _searchFocus.unfocus();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    if (_searchActive) {
      return AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Close search',
          onPressed: _closeSearch,
        ),
        title: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search circle…',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 12),
            filled: false,
          ),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          onChanged: (v) => setState(() => _searchQuery = v.trim()),
        ),
        actions: [
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_rounded),
              tooltip: 'Clear',
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
        ],
      );
    }

    return AppBar(
      title: const Text('Your Circle'),
      actions: [
        IconButton(
          tooltip: 'Search',
          icon: const Icon(Icons.search_rounded),
          onPressed: _openSearch,
        ),
        IconButton(
          tooltip: 'Invite to circle',
          icon: const Icon(Icons.person_add_alt_1_rounded),
          onPressed: () => _showInviteSheet(context),
        ),
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _busy ? null : _load,
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: List.generate(4, (i) => _skeletonRow(i)),
      );
    }

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 32),
      children: [
        // Error banner
        if (_error != null) _buildErrorBanner(),

        // Pending notifications strip — only when there are pending requests
        if (!_searchActive && _incomingRequests.isNotEmpty)
          _buildPendingRequestsStrip(),

        // Sent invitations — collapsed, accessible but not dominant
        if (!_searchActive && _sentInvitations.isNotEmpty)
          _buildSentInvitationsStrip(),

        // Member list
        _buildMemberList(),
      ],
    );
  }

  // ── Error banner ─────────────────────────────────────────────────────────

  Widget _buildErrorBanner() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Padding(
        key: ValueKey('error-$_error'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFFECACA)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded,
                  color: Color(0xFFDC2626), size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFB91C1C),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => _setError(null),
                child: const Icon(Icons.close_rounded,
                    color: Color(0xFF991B1B), size: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Pending requests strip ────────────────────────────────────────────────

  Widget _buildPendingRequestsStrip() {
    final requests = _incomingRequests;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _showIncomingRequestsSheet(context, requests),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E60AA),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.mail_rounded,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        requests.length == 1
                            ? '1 connection request'
                            : '${requests.length} connection requests',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: Color(0xFF1E40AF),
                        ),
                      ),
                      const Text(
                        'Tap to review and respond',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF3B82F6)),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFF3B82F6), size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Sent invitations strip ────────────────────────────────────────────────

  Widget _buildSentInvitationsStrip() {
    final pending = _sentInvitations.where((r) => r['status'] == 'pending').length;
    final declined = _sentInvitations.where((r) => r['status'] == 'rejected').length;
    String subtitle;
    if (pending > 0 && declined > 0) {
      subtitle = '$pending pending · $declined declined';
    } else if (pending > 0) {
      subtitle = '$pending awaiting response';
    } else {
      subtitle = '$declined declined';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showSentInvitationsSheet(context, _sentInvitations),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.send_rounded,
                    color: Color(0xFF64748B), size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'Sent Invitations  ',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Color(0xFF0F172A)),
                        ),
                        TextSpan(
                          text: subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Color(0xFF94A3B8), size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Member list ─────────────────────────────────────────────────────────

  Widget _buildMemberList() {
    final people = _filteredPeople;

    if (_searchActive && _searchQuery.isNotEmpty && people.isEmpty) {
      return _buildSearchEmpty();
    }

    if (!_searchActive && _people.isEmpty) {
      return _buildEmptyCircle();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_searchActive) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(
                  '${_people.length} ${_people.length == 1 ? 'member' : 'members'}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '${people.length} result${people.length == 1 ? '' : 's'}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF64748B),
              ),
            ),
          ),
        ],
        // White card containing the list
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Column(
              children: [
                for (int i = 0; i < people.length; i++) ...[
                  _buildMemberRow(people[i]),
                  if (i < people.length - 1)
                    const Divider(
                        height: 1,
                        indent: 68,
                        endIndent: 0,
                        color: Color(0xFFF1F5F9)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Compact member row ──────────────────────────────────────────────────

  Widget _buildMemberRow(Map<String, dynamic> person) {
    final otherId = person['other_id'] as String;
    final name = person['display_name'] as String? ?? 'Member';
    final rel = person['relationship'] as String? ?? 'Friend';
    final avatarUrl = person['avatar_url'] as String?;
    final isSharingWithThem = _sharing[otherId] ?? false;
    final theyShareWithMe = _incomingSharing[otherId] ?? false;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showMemberSheet(
          context,
          person: person,
          otherId: otherId,
          name: name,
          rel: rel,
          isSharingWithThem: isSharingWithThem,
          theyShareWithMe: theyShareWithMe,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Avatar ──────────────────────────────────────────────
              KaSpotAvatar(
                name: name,
                avatarUrl: avatarUrl,
                size: 44,
                isCircle: true,
              ),
              const SizedBox(width: 12),

              // ── Name + badges + status ───────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Name line
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: Color(0xFF0F172A),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _relationshipBadgeSmall(rel),
                      ],
                    ),
                    const SizedBox(height: 3),
                    // Sharing status — compact, two directions
                    _buildSharingStatusLine(
                        isSharingWithThem: isSharingWithThem,
                        theyShareWithMe: theyShareWithMe),
                  ],
                ),
              ),

              // ── Trailing actions ──────────────────────────────────────
              const SizedBox(width: 8),
              _buildMessageIconButton(otherId, name, avatarUrl, theyShareWithMe),
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                tooltip: 'More options',
                icon: const Icon(Icons.more_vert_rounded,
                    size: 20, color: Color(0xFF94A3B8)),
                onPressed: () => _showPersonOptions(person),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Sharing status line ─────────────────────────────────────────────────

  Widget _buildSharingStatusLine({
    required bool isSharingWithThem,
    required bool theyShareWithMe,
  }) {
    // Build one concise status line representing both directions
    if (isSharingWithThem && theyShareWithMe) {
      return _statusChip(
        label: 'Sharing with each other',
        dotColor: const Color(0xFF10B981),
        textColor: const Color(0xFF059669),
      );
    }
    if (isSharingWithThem && !theyShareWithMe) {
      return _statusChip(
        label: 'You are sharing · they are not',
        dotColor: const Color(0xFFF59E0B),
        textColor: const Color(0xFF92400E),
      );
    }
    if (!isSharingWithThem && theyShareWithMe) {
      return _statusChip(
        label: 'They share with you · you are hidden',
        dotColor: const Color(0xFF3B82F6),
        textColor: const Color(0xFF1D4ED8),
      );
    }
    return _statusChip(
      label: 'Location sharing off',
      dotColor: const Color(0xFFCBD5E1),
      textColor: const Color(0xFF94A3B8),
    );
  }

  Widget _statusChip({
    required String label,
    required Color dotColor,
    required Color textColor,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // ── Message icon button with unread badge ────────────────────────────────

  Widget _buildMessageIconButton(
      String otherId, String name, String? avatarUrl, bool theyShareWithMe) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: KaSpotService.unreadCounts,
      builder: (context, counts, _) {
        final unread = counts[otherId] ?? 0;
        final hasUnread = unread > 0;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              tooltip: 'Message',
              icon: Icon(
                hasUnread
                    ? Icons.chat_bubble_rounded
                    : Icons.chat_bubble_outline_rounded,
                size: 22,
                color:
                    hasUnread ? const Color(0xFF1E60AA) : const Color(0xFF94A3B8),
              ),
              onPressed: () async {
                await KaSpotService.markMessagesRead(otherId);
                if (!context.mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CircleChatScreen(
                      otherId: otherId,
                      displayName: name,
                      avatarUrl: avatarUrl,
                      theyShareWithMe: theyShareWithMe,
                    ),
                  ),
                );
              },
            ),
            if (hasUnread)
              Positioned(
                top: 0,
                right: 0,
                child: IgnorePointer(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    constraints:
                        const BoxConstraints(minWidth: 16, minHeight: 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: Text(
                      unread > 99 ? '99+' : '$unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  // ── Small relationship badge ─────────────────────────────────────────────

  Widget _relationshipBadgeSmall(String relationship) {
    Color bg;
    Color text;
    switch (relationship) {
      case 'Partner':
        bg = const Color(0xFFFFE4E6);
        text = const Color(0xFFE11D48);
        break;
      case 'Family':
        bg = const Color(0xFFF3E8FF);
        text = const Color(0xFF7C3AED);
        break;
      default:
        bg = const Color(0xFFE0F2FE);
        text = const Color(0xFF0284C7);
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        relationship,
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w800, color: text),
      ),
    );
  }

  // ── Skeleton rows (loading) ──────────────────────────────────────────────

  Widget _skeletonRow(int index) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, index == 0 ? 16 : 0, 16, 0),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2E8F0),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 14,
                        width: 140 - (index * 10).toDouble(),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 11,
                        width: 100,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (index < 3)
            const Divider(
                height: 1, indent: 68, color: Color(0xFFF1F5F9)),
        ],
      ),
    );
  }

  // ── Empty states ─────────────────────────────────────────────────────────

  Widget _buildEmptyCircle() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFEBF5FF),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(Icons.people_outline_rounded,
                size: 36, color: Color(0xFF1E60AA)),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your Circle is empty',
            style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: Color(0xFF0F172A)),
          ),
          const SizedBox(height: 8),
          const Text(
            'Share your Circle Code with family or friends to connect. Location sharing is always an opt-in choice.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Color(0xFF64748B), height: 1.5, fontSize: 14),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _showInviteSheet(context),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            label: const Text('Invite Someone'),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchEmpty() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      child: Column(
        children: [
          const Icon(Icons.search_off_rounded,
              size: 48, color: Color(0xFF94A3B8)),
          const SizedBox(height: 16),
          Text(
            'No results for "$_searchQuery"',
            style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: Color(0xFF0F172A)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          const Text(
            'Try a different name.',
            style: TextStyle(color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }

  // ── Invite bottom sheet ───────────────────────────────────────────────────

  Future<void> _showInviteSheet(BuildContext context) async {
    final idController = TextEditingController();
    String? sheetError;
    bool sheetBusy = false;
    final myCode = KaSpotService.accountCode;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Header ──────────────────────────────────────────
                      const Text(
                        'Invite to Your Circle',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Connecting always requires mutual consent.',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFF64748B)),
                      ),
                      const SizedBox(height: 20),

                      // ── Your code section ────────────────────────────────
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Your Circle Code (share with friends)',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF64748B)),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    myCode,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                ),
                                // Copy
                                IconButton(
                                  tooltip: 'Copy',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.copy_rounded,
                                      size: 18,
                                      color: Color(0xFF1E60AA)),
                                  onPressed: () {
                                    Clipboard.setData(
                                        ClipboardData(text: myCode));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                            'Circle Code $myCode copied.'),
                                        behavior: SnackBarBehavior.floating,
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(14)),
                                      ),
                                    );
                                  },
                                ),
                                // Share
                                IconButton(
                                  tooltip: 'Share',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.share_rounded,
                                      size: 18,
                                      color: Color(0xFF1E60AA)),
                                  onPressed: () {
                                    SharePlus.instance.share(
                                      ShareParams(
                                        text: 'Join my KaSpot Circle! My Circle Code is $myCode. Download KaSpot and enter this code to connect.',
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),

                      // ── Send invitation section ──────────────────────────
                      const Text(
                        "Enter a friend's Circle Code",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A)),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: idController,
                        textCapitalization: TextCapitalization.characters,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          hintText: 'KS-XXXX-XXXX',
                          prefixIcon:
                              Icon(Icons.badge_outlined, size: 20),
                        ),
                        onChanged: (_) {
                          if (sheetError != null) {
                            setSheetState(() => sheetError = null);
                          }
                        },
                      ),

                      // Sheet-level error
                      if (sheetError != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: const Color(0xFFFECACA)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  color: Color(0xFFDC2626), size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  sheetError!,
                                  style: const TextStyle(
                                      color: Color(0xFFB91C1C),
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: sheetBusy
                              ? null
                              : () async {
                                  final code =
                                      idController.text.trim();
                                  if (code.isEmpty) {
                                    setSheetState(() => sheetError =
                                        'Please enter a Circle Code.');
                                    return;
                                  }
                                  setSheetState(
                                      () => sheetBusy = true);
                                  try {
                                    await KaSpotService.sendRequest(code);
                                    idController.clear();
                                    await _load();
                                    if (ctx.mounted) {
                                      Navigator.pop(ctx);
                                      _notify(
                                          'Connection request sent.');
                                    }
                                  } catch (e) {
                                    setSheetState(() {
                                      sheetError = e
                                          .toString()
                                          .replaceFirst('Exception: ', '');
                                      sheetBusy = false;
                                    });
                                  }
                                },
                          icon: sheetBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white),
                                )
                              : const Icon(Icons.send_rounded, size: 16),
                          label: const Text('Send Invitation'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    idController.dispose();
  }

  // ── Incoming requests sheet ───────────────────────────────────────────────

  Future<void> _showIncomingRequestsSheet(
      BuildContext context, List<Map<String, dynamic>> requests) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Connection Requests (${requests.length})',
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Accept to share locations with this person.',
                  style:
                      TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 16),
                ...requests.map((req) => _requestTile(req, ctx)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _requestTile(Map<String, dynamic> request, BuildContext sheetContext) {
    final reqId = request['id'] as String;
    final name =
        request['counterpart_name'] as String? ?? 'KaSpot member';
    final code = request['counterpart_code'] as String? ?? '';
    final avatarUrl = request['counterpart_avatar'] as String?;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          KaSpotAvatar(
              name: name, avatarUrl: avatarUrl, size: 42, isCircle: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: Color(0xFF0F172A)),
                  overflow: TextOverflow.ellipsis,
                ),
                if (code.isNotEmpty)
                  Text(
                    code,
                    style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: Color(0xFF64748B)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () {
                    Navigator.pop(sheetContext);
                    _run(
                        () => KaSpotService.respondToRequest(
                            reqId, 'rejected'),
                        'Declined.');
                  },
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
            ),
            child: const Text('Decline'),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: _busy
                ? null
                : () {
                    Navigator.pop(sheetContext);
                    _run(
                        () => KaSpotService.respondToRequest(
                            reqId, 'accepted'),
                        'Connected!');
                  },
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 8),
            ),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  // ── Sent invitations sheet ────────────────────────────────────────────────

  Future<void> _showSentInvitationsSheet(
      BuildContext context, List<Map<String, dynamic>> invitations) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Sent Invitations',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A)),
                ),
                const SizedBox(height: 16),
                ...invitations.map((req) {
                  final reqId = req['id'] as String;
                  final isPending =
                      (req['status'] as String? ?? 'pending') == 'pending';
                  final name =
                      req['counterpart_name'] as String? ?? 'KaSpot member';
                  final code = req['counterpart_code'] as String? ?? '';
                  final avatarUrl = req['counterpart_avatar'] as String?;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        KaSpotAvatar(
                            name: name,
                            avatarUrl: avatarUrl,
                            size: 40,
                            isCircle: true),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14,
                                    color: Color(0xFF0F172A)),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (code.isNotEmpty)
                                Text(
                                  code,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      color: Color(0xFF64748B)),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (isPending) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF7ED),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: const Color(0xFFFED7AA)),
                            ),
                            child: const Text(
                              'Pending',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFC2410C)),
                            ),
                          ),
                          const SizedBox(width: 6),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () {
                                    Navigator.pop(ctx);
                                    _run(
                                        () => KaSpotService.cancelRequest(
                                            reqId),
                                        'Invitation cancelled.');
                                  },
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                              foregroundColor: const Color(0xFF64748B),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ] else
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: const Color(0xFFE2E8F0)),
                            ),
                            child: const Text(
                              'Declined',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF64748B)),
                            ),
                          ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Member detail bottom sheet ────────────────────────────────────────────

  Future<void> _showMemberSheet(
    BuildContext context, {
    required Map<String, dynamic> person,
    required String otherId,
    required String name,
    required String rel,
    required bool isSharingWithThem,
    required bool theyShareWithMe,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return _MemberDetailSheet(
          person: person,
          otherId: otherId,
          name: name,
          rel: rel,
          isSharingWithThem: isSharingWithThem,
          theyShareWithMe: theyShareWithMe,
          busy: _busy,
          onMessage: () async {
            Navigator.pop(sheetContext);
            await KaSpotService.markMessagesRead(otherId);
            if (!context.mounted) return;
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CircleChatScreen(
                  otherId: otherId,
                  displayName: name,
                  avatarUrl: person['avatar_url'] as String?,
                  theyShareWithMe: theyShareWithMe,
                ),
              ),
            );
          },
          onToggleSharing: (val) async {
            Navigator.pop(sheetContext);
            await _run(
              () => _setSharing(otherId, val),
              val
                  ? 'Location sharing enabled for ${name.split(' ').first}.'
                  : 'Sharing stopped.',
            );
          },
          onChangeRelationship: () {
            Navigator.pop(sheetContext);
            _changeCategorySheet(person);
          },
          onRemove: () {
            Navigator.pop(sheetContext);
            _confirmRemove(person);
          },
        );
      },
    );
  }

  // ── Person options (overflow menu) ───────────────────────────────────────

  Future<void> _showPersonOptions(Map<String, dynamic> person) async {
    final name = person['display_name'] as String? ?? 'Member';
    final rel = person['relationship'] as String? ?? 'Friend';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.category_outlined,
                  color: Color(0xFF1E60AA)),
              title: const Text('Change Circle Category',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('Currently: $rel'),
              onTap: () {
                Navigator.pop(context);
                _changeCategorySheet(person);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined,
                  color: Color(0xFFDC2626)),
              title: Text('Remove $name from Circle',
                  style: const TextStyle(
                      color: Color(0xFFDC2626),
                      fontWeight: FontWeight.w700)),
              onTap: () {
                Navigator.pop(context);
                _confirmRemove(person);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Relationship change sheet ─────────────────────────────────────────────

  Future<void> _changeCategorySheet(Map<String, dynamic> person) async {
    final otherId = person['other_id'] as String;
    final name = person['display_name'] as String? ?? 'Member';
    final currentRel = person['relationship'] as String? ?? 'Friend';

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Circle Category for $name',
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 4),
              const Text(
                'Categorise this connection to tailor alerts and map labels.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              _relOptionTile(
                  'Partner',
                  'Spouse or significant other',
                  Icons.favorite_rounded,
                  const Color(0xFFE11D48),
                  currentRel, () async {
                Navigator.pop(context);
                await _run(
                    () => KaSpotService.setCircleRelationship(
                        otherId, 'Partner'),
                    'Updated $name to Partner.');
              }),
              _relOptionTile(
                  'Family',
                  'Parents, children, siblings, relatives',
                  Icons.family_restroom_rounded,
                  const Color(0xFF7C3AED),
                  currentRel, () async {
                Navigator.pop(context);
                await _run(
                    () => KaSpotService.setCircleRelationship(
                        otherId, 'Family'),
                    'Updated $name to Family.');
              }),
              _relOptionTile(
                  'Friend',
                  'Friends, coworkers, and trusted peers',
                  Icons.people_alt_rounded,
                  const Color(0xFF0284C7),
                  currentRel, () async {
                Navigator.pop(context);
                await _run(
                    () => KaSpotService.setCircleRelationship(
                        otherId, 'Friend'),
                    'Updated $name to Friend.');
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _relOptionTile(
    String title,
    String desc,
    IconData icon,
    Color color,
    String currentRel,
    VoidCallback onTap,
  ) {
    final isSelected = currentRel == title;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? color.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isSelected ? color : const Color(0xFFE2E8F0)),
      ),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(title,
            style:
                TextStyle(fontWeight: FontWeight.w800, color: color)),
        subtitle: Text(desc,
            style: const TextStyle(
                fontSize: 12, color: Color(0xFF64748B))),
        trailing:
            isSelected ? Icon(Icons.check_circle_rounded, color: color) : null,
        onTap: onTap,
      ),
    );
  }

  // ── Remove confirmation ──────────────────────────────────────────────────

  Future<void> _confirmRemove(Map<String, dynamic> person) async {
    final name = person['display_name'] as String? ?? 'Member';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
          'This will end the connection and remove all location-sharing access in both directions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(
        () => KaSpotService.removeConnection(person['id'] as String),
        'Removed from circle.',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// _MemberDetailSheet — bottom sheet with full member details + sharing controls
// ---------------------------------------------------------------------------

class _MemberDetailSheet extends StatefulWidget {
  const _MemberDetailSheet({
    required this.person,
    required this.otherId,
    required this.name,
    required this.rel,
    required this.isSharingWithThem,
    required this.theyShareWithMe,
    required this.busy,
    required this.onMessage,
    required this.onToggleSharing,
    required this.onChangeRelationship,
    required this.onRemove,
  });

  final Map<String, dynamic> person;
  final String otherId;
  final String name;
  final String rel;
  final bool isSharingWithThem;
  final bool theyShareWithMe;
  final bool busy;
  final VoidCallback onMessage;
  final ValueChanged<bool> onToggleSharing;
  final VoidCallback onChangeRelationship;
  final VoidCallback onRemove;

  @override
  State<_MemberDetailSheet> createState() => _MemberDetailSheetState();
}

class _MemberDetailSheetState extends State<_MemberDetailSheet> {
  late bool _isSharingWithThem;

  @override
  void initState() {
    super.initState();
    _isSharingWithThem = widget.isSharingWithThem;
  }

  @override
  Widget build(BuildContext context) {
    final rel = widget.rel;
    final name = widget.name;
    final avatarUrl = widget.person['avatar_url'] as String?;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Profile header ───────────────────────────────────────────
            Row(
              children: [
                KaSpotAvatar(
                  name: name,
                  avatarUrl: avatarUrl,
                  size: 56,
                  isCircle: true,
                  showBorder: true,
                  borderColor: const Color(0xFFE2E8F0),
                  borderWidth: 2,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: Color(0xFF0F172A),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      _buildRelBadge(rel),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Location sharing section ─────────────────────────────────
            const Text(
              'Location Sharing',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF64748B),
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),

            // Their sharing with me (read-only — they control this)
            _sharingStatusTile(
              icon: widget.theyShareWithMe
                  ? Icons.location_on_rounded
                  : Icons.location_off_outlined,
              iconColor: widget.theyShareWithMe
                  ? const Color(0xFF10B981)
                  : const Color(0xFF94A3B8),
              label: widget.theyShareWithMe
                  ? '$name is sharing their location with you'
                  : '$name is not sharing their location with you',
              sublabel: widget.theyShareWithMe ? null : 'They control this setting.',
              active: widget.theyShareWithMe,
              control: null,
            ),
            const SizedBox(height: 8),

            // My sharing with them (toggle — I control this)
            _sharingStatusTile(
              icon: _isSharingWithThem
                  ? Icons.my_location_rounded
                  : Icons.location_off_outlined,
              iconColor: _isSharingWithThem
                  ? const Color(0xFF10B981)
                  : const Color(0xFF94A3B8),
              label: _isSharingWithThem
                  ? 'You are sharing your location with $name'
                  : 'Your location is hidden from $name',
              sublabel: null,
              active: _isSharingWithThem,
              control: widget.busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Switch.adaptive(
                      value: _isSharingWithThem,
                      activeTrackColor: const Color(0xFF10B981),
                      onChanged: widget.busy
                          ? null
                          : (val) {
                              setState(() {
                                _isSharingWithThem = val;
                              });
                              widget.onToggleSharing(val);
                            },
                    ),
            ),

            const SizedBox(height: 20),

            // ── Primary action — message ─────────────────────────────────
            ValueListenableBuilder<Map<String, int>>(
              valueListenable: KaSpotService.unreadCounts,
              builder: (context, counts, _) {
                final unread = counts[widget.otherId] ?? 0;
                final hasUnread = unread > 0;
                return FilledButton.icon(
                  onPressed: widget.onMessage,
                  icon: Badge(
                    isLabelVisible: hasUnread,
                    label: Text(unread > 99 ? '99+' : '$unread'),
                    child: const Icon(Icons.chat_bubble_outline_rounded,
                        size: 18),
                  ),
                  label: Text(hasUnread
                      ? 'Message ($unread unread)'
                      : 'Message ${name.split(' ').first}'),
                );
              },
            ),

            const SizedBox(height: 10),

            // ── Secondary actions ────────────────────────────────────────
            OutlinedButton.icon(
              onPressed: widget.onChangeRelationship,
              icon: const Icon(Icons.category_outlined, size: 18),
              label: Text('Change Circle Category · $rel'),
            ),

            const SizedBox(height: 6),

            // ── Destructive action ───────────────────────────────────────
            TextButton.icon(
              onPressed: widget.onRemove,
              icon: const Icon(Icons.person_remove_outlined,
                  size: 18, color: Color(0xFFDC2626)),
              label: Text(
                'Remove $name from Circle',
                style: const TextStyle(color: Color(0xFFDC2626)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sharingStatusTile({
    required IconData icon,
    required Color iconColor,
    required String label,
    String? sublabel,
    required bool active,
    required Widget? control,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFFF0FDF4)
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active
              ? const Color(0xFFBBF7D0)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? const Color(0xFF0F172A)
                        : const Color(0xFF64748B),
                  ),
                ),
                if (sublabel != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sublabel,
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFF94A3B8)),
                  ),
                ],
              ],
            ),
          ),
          if (control != null) ...[
            const SizedBox(width: 8),
            control,
          ],
        ],
      ),
    );
  }

  Widget _buildRelBadge(String relationship) {
    Color bg;
    Color text;
    IconData icon;
    switch (relationship) {
      case 'Partner':
        bg = const Color(0xFFFFE4E6);
        text = const Color(0xFFE11D48);
        icon = Icons.favorite_rounded;
        break;
      case 'Family':
        bg = const Color(0xFFF3E8FF);
        text = const Color(0xFF7C3AED);
        icon = Icons.family_restroom_rounded;
        break;
      default:
        bg = const Color(0xFFE0F2FE);
        text = const Color(0xFF0284C7);
        icon = Icons.people_alt_rounded;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: text),
          const SizedBox(width: 5),
          Text(
            relationship,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w800, color: text),
          ),
        ],
      ),
    );
  }
}
