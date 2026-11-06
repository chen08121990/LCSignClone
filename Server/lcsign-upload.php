<?php
/**
 * LCSign「安装到桌面」上传接口
 * ---------------------------------------------------------------
 * 部署：把本文件放到网站根目录（例如 https://example.com/lcsign-upload.php），
 *       修改下面的 TOKEN，然后在 App 的安装设置里填同一个令牌。
 *
 * 协议：PUT 原始文件体
 *   Authorization: Bearer <TOKEN>
 *   X-LCSign-Path: lcsign/20261106/<uuid>/app.ipa
 * 响应：{"ok":true,"url":"https://example.com/lcsign/20261106/<uuid>/app.ipa"}
 *
 * 服务端要求：
 *   - nginx：client_max_body_size 512m;（默认只有 1m，会直接 413）
 *   - nginx：fastcgi_read_timeout 600s;（大包上传耗时长）
 *   - lcsign/ 目录必须允许直接访问，否则手机下载不到 IPA
 *   - .plist 建议映射成 application/xml（iOS 不强制，但部分 CDN 会改写）
 * ---------------------------------------------------------------
 */

declare(strict_types=1);

// ★ 必改：与 App 里填写的令牌保持一致，越长越好
const TOKEN = 'CHANGE-ME-TO-A-LONG-RANDOM-STRING';

// 单个文件上限（字节）。App 端最大只会上传签名后的 IPA。
const MAX_BYTES = 512 * 1024 * 1024;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

function fail(int $code, string $message): void
{
    http_response_code($code);
    echo json_encode(['ok' => false, 'error' => $message], JSON_UNESCAPED_UNICODE);
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'PUT') {
    header('Allow: PUT');
    fail(405, '只接受 PUT');
}

// ---------------------------------------------------------------
// 1. 令牌
// ---------------------------------------------------------------
$authorization = $_SERVER['HTTP_AUTHORIZATION']
    ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION']
    ?? '';

if ($authorization === '' && function_exists('getallheaders')) {
    foreach (getallheaders() as $name => $value) {
        if (strcasecmp($name, 'Authorization') === 0) {
            $authorization = $value;
            break;
        }
    }
}

if (!hash_equals('Bearer ' . TOKEN, $authorization)) {
    fail(401, '令牌不正确');
}

// ---------------------------------------------------------------
// 2. 路径
// ---------------------------------------------------------------
$path = $_SERVER['HTTP_X_LCSIGN_PATH'] ?? '';

// 白名单到字符级：只允许 App 生成的「lcsign/日期/uuid/文件名」，
// 这样 `..`、绝对路径、反斜杠之类的花招根本进不来。
if (!preg_match('#^lcsign/\d{8}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9._-]+$#', $path)) {
    fail(400, '路径不合法');
}
if (!preg_match('/\.(ipa|plist|txt)$/i', $path)) {
    fail(400, '只允许 ipa / plist / txt');
}

$destination = __DIR__ . '/' . $path;
$directory = dirname($destination);

if (!is_dir($directory) && !mkdir($directory, 0755, true) && !is_dir($directory)) {
    fail(500, '创建目录失败');
}

// ---------------------------------------------------------------
// 3. 落盘：先写临时文件，完成后再 rename
//
// 直接往目标文件写的话，手机可能在传输中途就开始下载，
// 拿到的是半个包 —— 安装必然失败，而且看不出原因。
// ---------------------------------------------------------------
$temporary = $destination . '.part-' . bin2hex(random_bytes(4));

$input = fopen('php://input', 'rb');
if ($input === false) {
    fail(500, '无法读取请求体');
}

$output = fopen($temporary, 'wb');
if ($output === false) {
    fclose($input);
    fail(500, '无法写入文件');
}

$written = 0;
$tooLarge = false;

while (!feof($input)) {
    $chunk = fread($input, 1024 * 1024);
    if ($chunk === false || $chunk === '') {
        continue;
    }
    $written += strlen($chunk);
    if ($written > MAX_BYTES) {
        $tooLarge = true;
        break;
    }
    if (fwrite($output, $chunk) === false) {
        fclose($input);
        fclose($output);
        @unlink($temporary);
        fail(500, '写入失败');
    }
}

fclose($input);
fclose($output);

if ($tooLarge) {
    @unlink($temporary);
    fail(413, '文件超过 ' . MAX_BYTES . ' 字节');
}

if (!rename($temporary, $destination)) {
    @unlink($temporary);
    fail(500, '保存失败');
}

@chmod($destination, 0644);

// ---------------------------------------------------------------
// 4. 返回公开地址
// ---------------------------------------------------------------
$https = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off')
    || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';

$host = $_SERVER['HTTP_HOST'] ?? '';
if ($host === '') {
    fail(500, '拿不到 Host');
}

$url = ($https ? 'https' : 'http') . '://' . $host . '/' . $path;

echo json_encode([
    'ok'    => true,
    'url'   => $url,
    'bytes' => $written,
], JSON_UNESCAPED_UNICODE);
