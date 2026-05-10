class McpServer {
  String name;
  String url;
  String fallbackUrl;
  String token;
  bool enabled;

  McpServer({
    required this.name,
    required this.url,
    this.fallbackUrl = '',
    this.token = '',
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'fallbackUrl': fallbackUrl,
        'token': token,
        'enabled': enabled,
      };

  factory McpServer.fromJson(Map<String, dynamic> j) => McpServer(
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        fallbackUrl: j['fallbackUrl'] as String? ?? '',
        token: j['token'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
      );
}
