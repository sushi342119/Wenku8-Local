/// 匿名接口的错误类型。
///
/// 账号体系（登录、云书架、签到、书评）已移除，这里仅保留匿名请求
/// 仍可能用到的错误表达：接口返回码与通用错误描述。
class WenkuApiError implements Exception {
  const WenkuApiError(this.code);
  final int code;
  String get message => '服务器未完成本次操作，请稍后重试';
  @override
  String toString() => message;
}

int? wenkuResponseCode(String source) => int.tryParse(source.trim());

String describeWenkuError(Object error) => error is WenkuApiError
    ? error.message
    : error is FormatException
        ? error.message.toString()
        : '网络或本地存储暂时异常，请重试';
