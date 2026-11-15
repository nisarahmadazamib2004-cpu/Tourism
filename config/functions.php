<?php
declare(strict_types=1);
require_once __DIR__ . '/session.php';
function e(mixed $v): string { return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function url(string $path = ''): string { return rtrim(BASE_URL, '/') . '/' . ltrim($path, '/'); }
function redirect(string $path): never { header('Location: ' . url($path)); exit; }
function csrf_token(): string { if (empty($_SESSION['_csrf'])) $_SESSION['_csrf'] = bin2hex(random_bytes(32)); return $_SESSION['_csrf']; }
function csrf_field(): string { return '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">'; }
function verify_csrf(?string $token): bool { return is_string($token) && hash_equals($_SESSION['_csrf'] ?? '', $token); }
function flash(string $key, ?string $value=null): ?string { if ($value !== null) { $_SESSION['_flash'][$key]=$value; return null; } $v=$_SESSION['_flash'][$key]??null; unset($_SESSION['_flash'][$key]); return $v; }
