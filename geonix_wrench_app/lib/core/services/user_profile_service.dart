import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';
import '../config/app_config.dart';
import '../models/invite.dart';
import '../models/member.dart';
import '../models/organization.dart';
import '../models/user_profile.dart';
import 'auth_http_helper.dart';

class UserProfileException implements Exception {
  UserProfileException(this.message);
  final String message;

  @override
  String toString() => message;
}

class UserProfileService {
  UserProfileService({required this.authService, this.baseUrl = kApiBaseUrl});

  final AuthService authService;
  final String baseUrl;

  String _detailFrom(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {}
    return 'Server returned ${response.statusCode}';
  }

  Future<http.Response> _get(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    try {
      return await http.get(uri, headers: await authHeader(authService));
    } catch (e) {
      throw UserProfileException('Could not reach the processing server');
    }
  }

  Future<http.Response> _post(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$baseUrl$path');
    try {
      return await http.post(
        uri,
        headers: {'Content-Type': 'application/json', ...await authHeader(authService)},
        body: jsonEncode(body),
      );
    } catch (e) {
      throw UserProfileException('Could not reach the processing server');
    }
  }

  Future<http.Response> _delete(String path) async {
    final uri = Uri.parse('$baseUrl$path');
    try {
      return await http.delete(uri, headers: await authHeader(authService));
    } catch (e) {
      throw UserProfileException('Could not reach the processing server');
    }
  }

  Map<String, dynamic> _decodeMap(http.Response response) {
    return (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  Future<UserProfile> fetchMe() async {
    final response = await _get('/api/auth/me');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return UserProfile.fromJson(_decodeMap(response));
  }

  Future<UserProfile> claimHandle(String handle) async {
    final response = await _post('/api/auth/handle', {'handle': handle});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return UserProfile.fromJson(_decodeMap(response));
  }

  /// Creates the shop. Only the name is sent: the seat limit is whatever the
  /// owner's Team subscription paid for, and the server is the one that knows.
  Future<Organization> createOrganization(String name) async {
    final response = await _post('/api/organizations', {'name': name});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return Organization.fromJson(_decodeMap(response));
  }

  Future<Organization?> fetchMyOrganization() async {
    final response = await _get('/api/organizations/me');
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return Organization.fromJson(_decodeMap(response));
  }

  Future<void> deleteOrganization(int orgId) async {
    final response = await _delete('/api/organizations/$orgId');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
  }

  Future<void> leaveOrganization() async {
    final response = await _delete('/api/organizations/me/leave');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
  }

  Future<List<Member>> fetchMembers(int orgId) async {
    final response = await _get('/api/organizations/$orgId/members');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    final decoded = jsonDecode(response.body) as List;
    return decoded.map((item) => Member.fromJson((item as Map).cast<String, dynamic>())).toList();
  }

  Future<void> removeMember(int orgId, int userId) async {
    final response = await _delete('/api/organizations/$orgId/members/$userId');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
  }

  Future<Invite> createInvite(int orgId, String handle) async {
    final response = await _post('/api/organizations/$orgId/invites', {'handle': handle});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return Invite.fromJson(_decodeMap(response));
  }

  Future<List<Invite>> fetchOrgInvites(int orgId) async {
    final response = await _get('/api/organizations/$orgId/invites');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    final decoded = jsonDecode(response.body) as List;
    return decoded.map((item) => Invite.fromJson((item as Map).cast<String, dynamic>())).toList();
  }

  Future<void> revokeInvite(int orgId, int inviteId) async {
    final response = await _delete('/api/organizations/$orgId/invites/$inviteId');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
  }

  Future<List<Invite>> fetchMyInvites() async {
    final response = await _get('/api/invites/me');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    final decoded = jsonDecode(response.body) as List;
    return decoded.map((item) => Invite.fromJson((item as Map).cast<String, dynamic>())).toList();
  }

  Future<UserProfile> acceptInvite(int inviteId) async {
    final response = await _post('/api/invites/$inviteId/accept', const {});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return UserProfile.fromJson(_decodeMap(response));
  }

  Future<Invite> declineInvite(int inviteId) async {
    final response = await _post('/api/invites/$inviteId/decline', const {});
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserProfileException(_detailFrom(response));
    }
    return Invite.fromJson(_decodeMap(response));
  }
}
