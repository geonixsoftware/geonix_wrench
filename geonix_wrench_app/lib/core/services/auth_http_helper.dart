import '../auth/auth_service.dart';

Future<Map<String, String>> authHeader(AuthService authService) async {
  return {'Authorization': 'Bearer ${await authService.getIdToken()}'};
}
