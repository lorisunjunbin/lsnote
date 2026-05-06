class Config {

  static final String primarySwatch = "primarySwatch";
  static final String hiddenDone = "hiddenDone";
  static final String aiHost = "aiHost";
  static final String aiPort = "aiPort";

  final int? id;
  final String? name;
  final String? value;

  Config({this.id, this.name, this.value});

  Config.fromJsonMap(Map<String, dynamic> map)
      : id = map['id'] as int,
        name = map['name'] as String,
        value = map['value'] as String;

  Map<String, dynamic> toJsonMap() => {
        'id': id,
        'name': name,
        'value': value,
      };
}
