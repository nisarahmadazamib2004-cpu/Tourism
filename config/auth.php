<?php
declare(strict_types=1);
require_once __DIR__.'/functions.php';
function require_login(): void { if (empty($_SESSION['user_id'])) redirect('auth/login.php'); }
function current_user_id(): ?int { return isset($_SESSION['user_id']) ? (int)$_SESSION['user_id'] : null; }
function logout_user(): void { $_SESSION=[]; if (ini_get('session.use_cookies')) { $p=session_get_cookie_params(); setcookie(session_name(), '', time()-42000, $p['path'],$p['domain'],$p['secure'],$p['httponly']); } session_destroy(); }
