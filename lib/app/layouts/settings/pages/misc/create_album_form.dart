import 'dart:async';

import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

class CreateAlbumForm extends StatefulWidget {
  const CreateAlbumForm({super.key});

  @override
  State<CreateAlbumForm> createState() => _CreateAlbumFormState();
}

class _CreateAlbumFormState extends OptimizedState<CreateAlbumForm> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _inviteeController = TextEditingController();
  final List<String> _invitees = [];
  String? _nameError;
  String? _inviteeError;
  bool _isSubmitting = false;

  // Whether invitees can add their own photos to the album. macOS Photos
  // defaults this on (`allowcontributions: "1"`); we mirror that default
  // and let the user opt out before creating.
  bool _allowContributions = true;

  // Contact search state
  List<Contact> _allContacts = [];
  List<Contact> _filteredContacts = [];
  bool _showSuggestions = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _inviteeController.addListener(_onInviteeTextChanged);
  }

  void _loadContacts() {
    try {
      final query = (Database.contacts.query()..order(Contact_.displayName)).build();
      _allContacts = query.find().toSet().toList();
    } catch (_) {
      // Contacts may not be available (e.g., in debug mode without auth)
      _allContacts = [];
    }
  }

  void _onInviteeTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      final query = _inviteeController.text.trim().toLowerCase();
      if (query.isEmpty) {
        setState(() {
          _filteredContacts = [];
          _showSuggestions = false;
        });
        return;
      }
      final filtered = _allContacts.where((c) {
        return c.displayName.toLowerCase().contains(query) ||
            c.phones.any((p) => p.toLowerCase().contains(query)) ||
            c.emails.any((e) => e.toLowerCase().contains(query));
      }).toList();
      setState(() {
        _filteredContacts = filtered;
        _showSuggestions = filtered.isNotEmpty;
      });
    });
  }

  void _addInviteeFromContact(String address) {
    final value = address.trim();
    if (value.isEmpty) return;

    if (_invitees.length >= 100) {
      setState(() => _inviteeError = 'Maximum 100 invitees reached');
      return;
    }

    final normalized = _normalizeInvitee(value);
    if (_invitees.any((i) => _normalizeInvitee(i) == normalized)) {
      setState(() => _inviteeError = 'This invitee is already added');
      return;
    }

    setState(() {
      _invitees.add(value);
      _inviteeController.clear();
      _inviteeError = null;
      _showSuggestions = false;
      _filteredContacts = [];
    });
  }

  String? _validateName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Album name is required';
    if (trimmed.length > 255) return 'Name exceeds maximum length (255 characters)';
    return null;
  }

  bool _isValidEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  bool _isValidPhone(String value) {
    final digits = value.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    return digits.length >= 7 && digits.length <= 15 && RegExp(r'^\d+$').hasMatch(digits);
  }

  String _normalizeInvitee(String value) {
    if (_isValidEmail(value)) return value.toLowerCase().trim();
    // Phone: strip formatting
    return value.replaceAll(RegExp(r'[\s\-\(\)]'), '').trim();
  }

  void _addInvitee() {
    final value = _inviteeController.text.trim();
    if (value.isEmpty) return;

    if (!_isValidEmail(value) && !_isValidPhone(value)) {
      setState(() => _inviteeError = 'Enter a valid email address or phone number');
      return;
    }

    if (_invitees.length >= 100) {
      setState(() => _inviteeError = 'Maximum 100 invitees reached');
      return;
    }

    final normalized = _normalizeInvitee(value);
    if (_invitees.any((i) => _normalizeInvitee(i) == normalized)) {
      setState(() => _inviteeError = 'This invitee is already added');
      return;
    }

    setState(() {
      _invitees.add(value);
      _inviteeController.clear();
      _inviteeError = null;
      _showSuggestions = false;
      _filteredContacts = [];
    });
  }

  void _removeInvitee(int index) {
    setState(() => _invitees.removeAt(index));
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final error = _validateName(_nameController.text);
    if (error != null) {
      setState(() => _nameError = error);
      return;
    }

    setState(() {
      _isSubmitting = true;
      _nameError = null;
    });

    try {
      Logger.info("[CreateAlbum] Dart: calling api.createAlbum name=$name allowContributions=$_allowContributions invitees=$_invitees", tag: "SharedAlbum");
      await api.createAlbum(
        lock: pushService.state!.icloudServices!.sharedstreams!,
        name: name,
        allowContributions: _allowContributions,
        invitees: _invitees,
      );
      Logger.info("[CreateAlbum] Dart: SUCCESS", tag: "SharedAlbum");
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Exception catch (e) {
      Logger.error("[CreateAlbum] Dart: EXCEPTION: $e", tag: "SharedAlbum");
      if (!mounted) return;
      final msg = e.toString();
      String errorMessage;
      if (msg.contains('timeout') || msg.contains('network') || msg.contains('ConnectError')) {
        errorMessage = 'Network error. Check your connection and try again.';
      } else if (msg.contains('401') || msg.contains('auth') || msg.contains('Auth')) {
        errorMessage = 'Authentication failed. Please re-authenticate your iCloud account.';
      } else if (RegExp(r'\b5\d{2}\b').hasMatch(msg)) {
        errorMessage = 'Server error. Please try again later.';
      } else {
        errorMessage = 'Failed to create album: $msg';
      }
      showSnackbar('Error', errorMessage);
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nameValid = _validateName(_nameController.text) == null &&
        _nameController.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Shared Album'),
        actions: [
          TextButton(
            onPressed: (_isSubmitting || !nameValid) ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Album name field
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Album Name',
              errorText: _nameError,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _nameError = null),
            textInputAction: TextInputAction.next,
            maxLength: 255,
          ),
          const SizedBox(height: 16),

          // Allow contributions toggle. Mirrors macOS Photos's "Subscribers Can Post"
          // option. Defaults to on, matching captured iOS/macOS behavior.
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Subscribers can post'),
            subtitle: const Text('Let invitees add their own photos to this album'),
            value: _allowContributions,
            onChanged: _isSubmitting ? null : (v) => setState(() => _allowContributions = v),
          ),
          const SizedBox(height: 8),

          // Invitee input
          Text('Invitees (optional)', style: context.theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _inviteeController,
                  decoration: InputDecoration(
                    hintText: 'Name, email, or phone number',
                    errorText: _inviteeError,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _addInvitee(),
                  onTap: () {
                    if (_inviteeController.text.isNotEmpty) {
                      _onInviteeTextChanged();
                    }
                  },
                  keyboardType: TextInputType.emailAddress,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _addInvitee,
                tooltip: 'Add invitee',
              ),
            ],
          ),

          // Contact suggestions dropdown
          if (_showSuggestions)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: context.theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.theme.colorScheme.outline.withOpacity(0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filteredContacts.length,
                itemBuilder: (context, index) {
                  final contact = _filteredContacts[index];
                  final addresses = [...contact.emails, ...contact.phones];
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: addresses.map((address) {
                      final isEmail = address.contains('@');
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isEmail ? Icons.email_outlined : Icons.phone_outlined,
                          size: 20,
                        ),
                        title: Text(contact.displayName),
                        subtitle: Text(address, style: context.theme.textTheme.bodySmall),
                        onTap: () => _addInviteeFromContact(address),
                      );
                    }).toList(),
                  );
                },
              ),
            ),

          const SizedBox(height: 8),

          // Invitee list
          ..._invitees.asMap().entries.map((entry) => ListTile(
                dense: true,
                title: Text(entry.value),
                leading: Icon(
                  entry.value.contains('@') ? Icons.email_outlined : Icons.phone_outlined,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                  onPressed: () => _removeInvitee(entry.key),
                  tooltip: 'Remove invitee',
                ),
              )),

          if (_invitees.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${_invitees.length}/100 invitees',
                style: context.theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _nameController.dispose();
    _inviteeController.dispose();
    super.dispose();
  }
}
