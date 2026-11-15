<?php
declare(strict_types=1);
if (session_status() !== PHP_SESSION_ACTIVE) {
    session_name('tourism_erp_session');
    session_start();
}
