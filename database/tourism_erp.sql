-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1
-- Generation Time: Oct 04, 2026 at 07:53 PM
-- Server version: 10.4.32-MariaDB
-- PHP Version: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `tourism_erp`
--

DELIMITER $$
--
-- Procedures
--
CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_business_accounting_audit` (IN `p_company_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER BEGIN

    SELECT
        'UNBALANCED_JOURNALS' AS audit_name,
        COUNT(*) AS issue_count
    FROM journal_entries
    WHERE company_id=p_company_id
      AND status IN ('posted','reversed')
      AND ROUND(total_debit-total_credit,4)<>0

    UNION ALL

    SELECT
        'POSTED_JOURNAL_LINE_MISMATCH',
        COUNT(*)
    FROM (
        SELECT
            je.id
        FROM journal_entries je
        LEFT JOIN journal_lines jl
          ON jl.company_id=je.company_id
         AND jl.journal_entry_id=je.id
        WHERE je.company_id=p_company_id
          AND je.status='posted'
        GROUP BY je.id
        HAVING ROUND(
            COALESCE(SUM(jl.debit_amount),0) -
            COALESCE(SUM(jl.credit_amount),0),
            4
        )<>0
    ) x

    UNION ALL

    SELECT
        'INVOICE_BALANCE_MISMATCH',
        COUNT(*)
    FROM invoices
    WHERE company_id=p_company_id
      AND status NOT IN ('cancelled','refunded')
      AND ROUND(
          total_amount-paid_amount-balance_amount,
          4
      )<>0

    UNION ALL

    SELECT
        'PROFIT_NEGATIVE_COMPONENT',
        COUNT(*)
    FROM finance_profit_records
    WHERE company_id=p_company_id
      AND (revenue_amount<0 OR cost_amount<0)

    UNION ALL

    SELECT
        'TRANSACTION_WITHOUT_PROFIT',
        COUNT(*)
    FROM finance_transaction_links ftl
    LEFT JOIN finance_profit_records fpr
      ON fpr.company_id=ftl.company_id
     AND fpr.transaction_type=ftl.transaction_type
     AND fpr.transaction_id=ftl.transaction_id
    WHERE ftl.company_id=p_company_id
      AND ftl.transaction_type IN (
          'ticket',
          'umrah',
          'hotel',
          'transport',
          'visa',
          'service'
      )
      AND fpr.id IS NULL

    UNION ALL

    SELECT
        'PROFIT_WITHOUT_JOURNAL',
        COUNT(*)
    FROM finance_profit_records
    WHERE company_id=p_company_id
      AND journal_entry_id IS NULL;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_close_finance_period` (IN `p_period_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)   BEGIN

    DECLARE v_company_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_unposted BIGINT DEFAULT 0;

    SELECT company_id,status
    INTO v_company_id,v_status
    FROM finance_periods
    WHERE id = p_period_id
    FOR UPDATE;

    IF v_company_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Finance period not found';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND company_id = v_company_id
          AND deleted_at IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid closing user';
    END IF;

    IF v_status <> 'open' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only open periods can be closed';
    END IF;

    SELECT COUNT(*)
    INTO v_unposted
    FROM journal_entries
    WHERE company_id = v_company_id
      AND period_id = p_period_id
      AND status = 'draft';

    IF v_unposted > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'Cannot close period while draft journal entries exist';
    END IF;

    UPDATE finance_periods
    SET status = 'closed',
        closed_at = NOW(),
        closed_by = p_user_id
    WHERE id = p_period_id;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_close_fiscal_year` (IN `p_fiscal_year_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)   BEGIN

    DECLARE v_company_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_open_periods BIGINT DEFAULT 0;
    DECLARE v_drafts BIGINT DEFAULT 0;

    SELECT company_id,status
    INTO v_company_id,v_status
    FROM finance_fiscal_years
    WHERE id = p_fiscal_year_id
    FOR UPDATE;

    IF v_company_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Fiscal year not found';
    END IF;

    IF v_status <> 'open' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only open fiscal years can be closed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND company_id = v_company_id
          AND deleted_at IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid fiscal year closing user';
    END IF;

    SELECT COUNT(*)
    INTO v_open_periods
    FROM finance_periods
    WHERE company_id = v_company_id
      AND fiscal_year_id = p_fiscal_year_id
      AND status = 'open';

    IF v_open_periods > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'All accounting periods must be closed first';
    END IF;

    SELECT COUNT(*)
    INTO v_drafts
    FROM journal_entries
    WHERE company_id = v_company_id
      AND fiscal_year_id = p_fiscal_year_id
      AND status = 'draft';

    IF v_drafts > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'Draft journal entries exist in fiscal year';
    END IF;

    UPDATE finance_fiscal_years
    SET status = 'closed',
        is_current = 0,
        closed_at = NOW(),
        closed_by = p_user_id,
        updated_by = p_user_id
    WHERE id = p_fiscal_year_id;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_database_performance_audit` ()  SQL SECURITY INVOKER BEGIN

    SELECT
        TABLE_NAME,
        INDEX_NAME,
        COLUMN_NAME,
        SEQ_IN_INDEX
    FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA='tourism_erp'
      AND TABLE_NAME IN (
          'ticket_bookings',
          'umrah_bookings',
          'hotel_bookings',
          'transport_bookings',
          'visas',
          'invoices',
          'invoice_items',
          'payments',
          'journal_entries',
          'journal_lines',
          'finance_customer_ledger',
          'finance_supplier_ledger',
          'finance_agency_ledger',
          'finance_profit_records'
      )
    ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_final_production_audit` (IN `p_company_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER main: BEGIN

    

    SELECT
        'REQUIRED_PROCEDURES' AS audit_group,
        ROUTINE_NAME,
        SECURITY_TYPE,
        ROUTINE_TYPE
    FROM information_schema.ROUTINES
    WHERE ROUTINE_SCHEMA = DATABASE()
      AND ROUTINE_NAME IN (
          'sp_next_document_number',
          'sp_post_invoice',
          'sp_post_journal_entry',
          'sp_reverse_journal_entry',
          'sp_validate_journal_entry',
          'sp_post_ticket',
          'sp_post_umrah',
          'sp_post_hotel',
          'sp_post_transport',
          'sp_post_visa',
          'sp_post_service',
          'sp_refund_invoice',
          'sp_finance_integrity_audit',
          'sp_business_accounting_audit',
          'sp_tenant_security_audit'
      )
    ORDER BY ROUTINE_NAME;

    

    SELECT
        'CORE_TABLES' AS audit_group,
        t.table_name,
        'EXISTS' AS status
    FROM information_schema.tables t
    WHERE t.table_schema = DATABASE()
      AND t.table_type = 'BASE TABLE'
      AND t.table_name IN (
          'companies',
          'branches',
          'users',
          'customers',
          'debtors',
          'suppliers',
          'agencies',
          'ticket_sources',
          'ticket_bookings',
          'umrah_bookings',
          'hotel_bookings',
          'transport_bookings',
          'visas',
          'invoices',
          'invoice_items',
          'payments',
          'payment_allocations',
          'finance_accounts',
          'finance_chart_accounts',
          'journal_entries',
          'journal_lines',
          'finance_customer_ledger',
          'finance_supplier_ledger',
          'finance_agency_ledger',
          'finance_service_costs',
          'finance_profit_records',
          'finance_transaction_links',
          'finance_refunds',
          'finance_fiscal_years',
          'finance_periods',
          'number_sequences'
      )
    ORDER BY t.table_name;

    

    CALL sp_finance_integrity_audit(p_company_id);

    

    CALL sp_business_accounting_audit(p_company_id);

    

    CALL sp_tenant_security_audit(p_company_id);

    

    SELECT
        'DUPLICATE_CHART_ACCOUNTS' AS audit_name,
        account_code,
        COUNT(*) AS duplicate_count
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND deleted_at IS NULL
    GROUP BY account_code
    HAVING COUNT(*) > 1;

    

    SELECT
        'DUPLICATE_FINANCE_ACCOUNTS' AS audit_name,
        account_no,
        COUNT(*) AS duplicate_count
    FROM finance_accounts
    WHERE company_id = p_company_id
      AND deleted_at IS NULL
    GROUP BY account_no
    HAVING COUNT(*) > 1;

    

    SELECT COUNT(*) AS cross_company_journal_lines
    FROM journal_lines jl
    INNER JOIN journal_entries je
        ON je.id = jl.journal_entry_id
    WHERE jl.company_id = p_company_id
      AND je.company_id <> jl.company_id;

    

    SELECT COUNT(*) AS cross_company_invoice_items
    FROM invoice_items ii
    INNER JOIN invoices i
        ON i.id = ii.invoice_id
    WHERE ii.company_id = p_company_id
      AND i.company_id <> ii.company_id;

    

    SELECT COUNT(*) AS invalid_finance_accounts
    FROM finance_accounts fa
    INNER JOIN finance_chart_accounts ca
        ON ca.id = fa.chart_account_id
    WHERE fa.company_id = p_company_id
      AND ca.company_id <> fa.company_id;

    

    SELECT COUNT(*) AS invalid_branches
    FROM branches b
    WHERE b.company_id = p_company_id
      AND NOT EXISTS (
          SELECT 1
          FROM companies c
          WHERE c.id = b.company_id
      );

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_finance_integrity_audit` (IN `p_company_id` BIGINT UNSIGNED)   BEGIN

    
    SELECT
        'UNBALANCED_JOURNALS' AS audit_name,
        COUNT(*) AS issue_count
    FROM journal_entries
    WHERE company_id = p_company_id
      AND ABS(total_debit-total_credit) > 0.0001;

    
    SELECT
        'JOURNAL_LINE_MISMATCH' AS audit_name,
        COUNT(*) AS issue_count
    FROM journal_entries je
    JOIN (
        SELECT
            company_id,
            journal_entry_id,
            SUM(debit_amount) AS debit_total,
            SUM(credit_amount) AS credit_total
        FROM journal_lines
        WHERE company_id = p_company_id
        GROUP BY company_id,journal_entry_id
    ) x
      ON x.company_id = je.company_id
     AND x.journal_entry_id = je.id
    WHERE je.company_id = p_company_id
      AND (
          ABS(je.total_debit-x.debit_total) > 0.0001
          OR
          ABS(je.total_credit-x.credit_total) > 0.0001
      );

    
    SELECT
        'INVOICE_BALANCE_MISMATCH' AS audit_name,
        COUNT(*) AS issue_count
    FROM invoices
    WHERE company_id = p_company_id
      AND ABS(
          balance_amount -
          GREATEST(total_amount-paid_amount,0)
      ) > 0.0001;

    
    SELECT
        'PAYMENT_OVER_ALLOCATION' AS audit_name,
        COUNT(*) AS issue_count
    FROM (
        SELECT
            p.company_id,
            p.id,
            p.amount,
            COALESCE(SUM(pa.allocated_amount),0) AS allocated
        FROM payments p
        LEFT JOIN payment_allocations pa
          ON pa.company_id = p.company_id
         AND pa.payment_id = p.id
        WHERE p.company_id = p_company_id
        GROUP BY p.company_id,p.id,p.amount
    ) x
    WHERE x.allocated > x.amount;

    
    SELECT
        'DUPLICATE_CHART_ACCOUNT_CODE' AS audit_name,
        COUNT(*) AS issue_count
    FROM (
        SELECT account_code
        FROM finance_chart_accounts
        WHERE company_id = p_company_id
          AND deleted_at IS NULL
        GROUP BY account_code
        HAVING COUNT(*) > 1
    ) x;

    
    SELECT
        'DUPLICATE_FINANCE_ACCOUNT_NO' AS audit_name,
        COUNT(*) AS issue_count
    FROM (
        SELECT account_no
        FROM finance_accounts
        WHERE company_id = p_company_id
          AND deleted_at IS NULL
        GROUP BY account_no
        HAVING COUNT(*) > 1
    ) x;

    
    SELECT
        'CROSS_COMPANY_JOURNAL_LINES' AS audit_name,
        COUNT(*) AS issue_count
    FROM journal_lines jl
    JOIN journal_entries je
      ON je.id = jl.journal_entry_id
    WHERE jl.company_id = p_company_id
      AND je.company_id <> jl.company_id;

    
    SELECT
        'CROSS_COMPANY_INVOICE_ITEMS' AS audit_name,
        COUNT(*) AS issue_count
    FROM invoice_items ii
    JOIN invoices i
      ON i.id = ii.invoice_id
    WHERE ii.company_id = p_company_id
      AND i.company_id <> ii.company_id;

    
    SELECT
        'AGENCY_LEDGER_INVALID_AMOUNT' AS audit_name,
        COUNT(*) AS issue_count
    FROM finance_agency_ledger
    WHERE company_id = p_company_id
      AND NOT (
          debit_amount > 0
          AND credit_amount = 0
          OR
          credit_amount > 0
          AND debit_amount = 0
      );

    
    SELECT
        'CUSTOMER_LEDGER_INVALID_AMOUNT' AS audit_name,
        COUNT(*) AS issue_count
    FROM finance_customer_ledger
    WHERE company_id = p_company_id
      AND NOT (
          debit_amount > 0
          AND credit_amount = 0
          OR
          credit_amount > 0
          AND debit_amount = 0
      );

    
    SELECT
        'SUPPLIER_LEDGER_INVALID_AMOUNT' AS audit_name,
        COUNT(*) AS issue_count
    FROM finance_supplier_ledger
    WHERE company_id = p_company_id
      AND NOT (
          debit_amount > 0
          AND credit_amount = 0
          OR
          credit_amount > 0
          AND debit_amount = 0
      );

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_next_document_number` (IN `p_company_id` BIGINT UNSIGNED, IN `p_branch_id` BIGINT UNSIGNED, IN `p_document_type` VARCHAR(80), OUT `p_document_number` VARCHAR(150))   BEGIN
    DECLARE v_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_prefix VARCHAR(30);
    DECLARE v_current BIGINT UNSIGNED DEFAULT 0;
    DECLARE v_padding TINYINT UNSIGNED DEFAULT 6;
    DECLARE v_reset_type VARCHAR(20);
    DECLARE v_last_reset_key VARCHAR(20);
    DECLARE v_new_reset_key VARCHAR(20);
    DECLARE v_number BIGINT UNSIGNED;

    SELECT
        id,
        prefix,
        current_number,
        padding,
        reset_type,
        last_reset_key
    INTO
        v_id,
        v_prefix,
        v_current,
        v_padding,
        v_reset_type,
        v_last_reset_key
    FROM number_sequences
    WHERE company_id = p_company_id
      AND branch_id <=> p_branch_id
      AND document_type = p_document_type
      AND status = 'active'
    LIMIT 1
    FOR UPDATE;

    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Active number sequence not found';
    END IF;

    SET v_new_reset_key =
        CASE v_reset_type
            WHEN 'yearly' THEN DATE_FORMAT(CURRENT_DATE, '%Y')
            WHEN 'monthly' THEN DATE_FORMAT(CURRENT_DATE, '%Y-%m')
            ELSE 'NEVER'
        END;

    IF v_reset_type <> 'never'
       AND (
            v_last_reset_key IS NULL
            OR v_last_reset_key <> v_new_reset_key
       )
    THEN
        SET v_number = 1;

        UPDATE number_sequences
        SET
            current_number = v_number,
            last_reset_key = v_new_reset_key,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_id;

    ELSE
        SET v_number = v_current + 1;

        UPDATE number_sequences
        SET
            current_number = v_number,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = v_id;
    END IF;

    SET p_document_number =
        CONCAT(
            v_prefix,
            LPAD(v_number, v_padding, '0')
        );
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_expense` (IN `p_expense_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)   main: BEGIN

    DECLARE v_company_id BIGINT UNSIGNED;
    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_expense_no VARCHAR(100);
    DECLARE v_expense_date DATETIME;
    DECLARE v_amount DECIMAL(20,4);
    DECLARE v_currency_code CHAR(3);
    DECLARE v_exchange_rate DECIMAL(20,8);
    DECLARE v_finance_account_id BIGINT UNSIGNED;
    DECLARE v_expense_account_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(30);
    DECLARE v_description TEXT;

    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);
    DECLARE v_journal_id BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        company_id,
        branch_id,
        expense_no,
        expense_date,
        amount,
        currency_code,
        exchange_rate,
        finance_account_id,
        expense_account_id,
        status,
        description
    INTO
        v_company_id,
        v_branch_id,
        v_expense_no,
        v_expense_date,
        v_amount,
        v_currency_code,
        v_exchange_rate,
        v_finance_account_id,
        v_expense_account_id,
        v_status,
        v_description
    FROM expenses
    WHERE id = p_expense_id
    FOR UPDATE;

    IF v_company_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Expense not found';
    END IF;

    IF v_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only draft expenses can be posted';
    END IF;

    IF v_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Expense amount must be greater than zero';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND company_id = v_company_id
          AND deleted_at IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid expense posting user';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM finance_accounts
        WHERE id = v_finance_account_id
          AND company_id = v_company_id
          AND status = 'active'
          AND deleted_at IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid expense payment account';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM finance_chart_accounts
        WHERE id = v_expense_account_id
          AND company_id = v_company_id
          AND allow_posting = 1
          AND status = 'active'
          AND deleted_at IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid expense chart account';
    END IF;

    SELECT id
    INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id = v_company_id
      AND v_expense_date >= start_date
      AND v_expense_date < DATE_ADD(end_date,INTERVAL 1 DAY)
      AND status = 'open'
    ORDER BY id DESC
    LIMIT 1;

    IF v_fiscal_year_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No open fiscal year for expense';
    END IF;

    SELECT id
    INTO v_period_id
    FROM finance_periods
    WHERE company_id = v_company_id
      AND fiscal_year_id = v_fiscal_year_id
      AND v_expense_date >= start_date
      AND v_expense_date < DATE_ADD(end_date,INTERVAL 1 DAY)
      AND status = 'open'
    LIMIT 1;

    IF v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No open accounting period for expense';
    END IF;

    IF v_expense_no IS NULL OR v_expense_no = '' THEN
        CALL sp_next_document_number(
            v_company_id,
            v_branch_id,
            'expense',
            v_expense_no
        );
    END IF;

    CALL sp_next_document_number(
        v_company_id,
        v_branch_id,
        'journal_entry',
        v_entry_no
    );

    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        created_by,
        updated_by
    )
    VALUES (
        v_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_entry_no,
        v_expense_date,
        'expense',
        p_expense_id,
        v_expense_no,
        COALESCE(v_description,CONCAT('Expense ',v_expense_no)),
        v_currency_code,
        v_exchange_rate,
        v_amount,
        v_amount,
        'draft',
        p_user_id,
        p_user_id
    );

    SET v_journal_id = LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        finance_account_id
    )
    VALUES (
        v_company_id,
        v_journal_id,
        v_expense_account_id,
        1,
        COALESCE(v_description,CONCAT('Expense ',v_expense_no)),
        v_amount,
        0,
        v_currency_code,
        v_exchange_rate,
        NULL
    );

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        finance_account_id
    )
    SELECT
        v_company_id,
        v_journal_id,
        chart_account_id,
        2,
        CONCAT('Paid expense ',v_expense_no),
        0,
        v_amount,
        v_currency_code,
        v_exchange_rate,
        v_finance_account_id
    FROM finance_accounts
    WHERE id = v_finance_account_id;

    CALL sp_validate_journal_entry(v_journal_id,p_user_id);
    CALL sp_post_journal_entry(v_journal_id,p_user_id);

    UPDATE expenses
    SET expense_no = v_expense_no,
        journal_entry_id = v_journal_id,
        status = 'posted',
        updated_by = p_user_id
    WHERE id = p_expense_id;

    INSERT INTO finance_transaction_links (
        company_id,
        branch_id,
        transaction_type,
        transaction_id,
        journal_entry_id,
        reference_no,
        notes,
        created_by
    )
    VALUES (
        v_company_id,
        v_branch_id,
        'expense',
        p_expense_id,
        v_journal_id,
        v_expense_no,
        'Expense accounting link',
        p_user_id
    );

    COMMIT;

    SELECT
        p_expense_id AS expense_id,
        v_expense_no AS expense_no,
        v_journal_id AS journal_entry_id,
        'posted' AS status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_hotel` (IN `p_company_id` BIGINT UNSIGNED, IN `p_hotel_booking_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER main: BEGIN

    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_hotel_id BIGINT UNSIGNED;
    DECLARE v_supplier_id BIGINT UNSIGNED;

    DECLARE v_reservation_no VARCHAR(100);
    DECLARE v_status VARCHAR(30);
    DECLARE v_date DATE;

    DECLARE v_cost DECIMAL(20,4);
    DECLARE v_selling DECIMAL(20,4);
    DECLARE v_currency CHAR(3);
    DECLARE v_exchange DECIMAL(20,8);
    DECLARE v_profit DECIMAL(20,4);

    DECLARE v_invoice_id BIGINT UNSIGNED;
    DECLARE v_invoice_no VARCHAR(100);

    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);

    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;

    DECLARE v_ar BIGINT UNSIGNED;
    DECLARE v_revenue BIGINT UNSIGNED;
    DECLARE v_cost_account BIGINT UNSIGNED;
    DECLARE v_payable BIGINT UNSIGNED;

    DECLARE v_exists INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        hb.branch_id,
        hb.customer_id,
        hb.debtor_id,
        hb.hotel_id,
        h.supplier_id,
        hb.reservation_no,
        hb.check_in,
        hb.supplier_cost,
        hb.selling_price,
        hb.currency_code,
        hb.exchange_rate,
        hb.status
    INTO
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_hotel_id,
        v_supplier_id,
        v_reservation_no,
        v_date,
        v_cost,
        v_selling,
        v_currency,
        v_exchange,
        v_status
    FROM hotel_bookings hb
    LEFT JOIN hotels h
      ON h.company_id = hb.company_id
     AND h.id = hb.hotel_id
    WHERE hb.company_id = p_company_id
      AND hb.id = p_hotel_booking_id
      AND hb.deleted_at IS NULL
    FOR UPDATE;

    IF v_reservation_no IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Hotel booking not found.';
    END IF;

    IF v_status NOT IN ('confirmed','checked_in','checked_out') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Hotel booking is not ready for accounting.';
    END IF;

    IF (v_customer_id IS NULL AND v_debtor_id IS NULL)
       OR
       (v_customer_id IS NOT NULL AND v_debtor_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Hotel booking must have exactly one customer or debtor.';
    END IF;

    IF v_selling < 0 OR v_cost < 0 OR v_exchange <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Invalid hotel financial amounts.';
    END IF;

    SELECT COUNT(*)
    INTO v_exists
    FROM finance_transaction_links
    WHERE company_id = p_company_id
      AND transaction_type = 'hotel'
      AND transaction_id = p_hotel_booking_id;

    IF v_exists > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Hotel booking already posted.';
    END IF;

    SELECT id
    INTO v_ar
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '1410'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id
    INTO v_revenue
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '4300'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id
    INTO v_cost_account
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '5300'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id
    INTO v_payable
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '2110'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_ar IS NULL
       OR v_revenue IS NULL
       OR v_cost_account IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Required Hotel accounting accounts are missing.';
    END IF;

    IF v_cost > 0
       AND (v_supplier_id IS NULL OR v_payable IS NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Hotel cost requires a supplier and supplier payable account.';
    END IF;

    SELECT id
    INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id = p_company_id
      AND v_date BETWEEN start_date AND end_date
      AND status = 'open'
    ORDER BY start_date DESC
    LIMIT 1;

    IF v_fiscal_year_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No open fiscal year for hotel transaction.';
    END IF;

    SELECT id
    INTO v_period_id
    FROM finance_periods
    WHERE company_id = p_company_id
      AND fiscal_year_id = v_fiscal_year_id
      AND v_date BETWEEN start_date AND end_date
      AND status = 'open'
    LIMIT 1;

    IF v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No open finance period for hotel transaction.';
    END IF;

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'invoice',
        v_invoice_no
    );

    INSERT INTO invoices (
        company_id,
        branch_id,
        invoice_no,
        invoice_date,
        customer_id,
        debtor_id,
        currency_code,
        exchange_rate,
        subtotal,
        discount_amount,
        tax_amount,
        total_amount,
        paid_amount,
        balance_amount,
        invoice_type,
        status,
        notes,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_invoice_no,
        v_date,
        v_customer_id,
        v_debtor_id,
        v_currency,
        v_exchange,
        v_selling,
        0,
        0,
        v_selling,
        0,
        v_selling,
        'hotel',
        'issued',
        CONCAT('Hotel booking ', v_reservation_no),
        p_user_id,
        p_user_id
    );

    SET v_invoice_id = LAST_INSERT_ID();

    INSERT INTO invoice_items (
        company_id,
        invoice_id,
        line_no,
        description,
        quantity,
        unit_price,
        discount_amount,
        tax_amount,
        hotel_booking_id
    )
    VALUES (
        p_company_id,
        v_invoice_id,
        1,
        CONCAT('Hotel Booking ', v_reservation_no),
        1,
        v_selling,
        0,
        0,
        p_hotel_booking_id
    );

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'journal_entry',
        v_entry_no
    );

    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_entry_no,
        v_date,
        'hotel',
        p_hotel_booking_id,
        v_reservation_no,
        CONCAT('Hotel accounting - ', v_reservation_no),
        v_currency,
        v_exchange,
        v_selling + v_cost,
        v_selling + v_cost,
        'draft',
        p_user_id,
        p_user_id
    );

    SET v_journal_id = LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        customer_id,
        debtor_id
    )
    VALUES (
        p_company_id,
        v_journal_id,
        v_ar,
        1,
        CONCAT('Hotel receivable - ', v_reservation_no),
        v_selling,
        0,
        v_currency,
        v_exchange,
        v_customer_id,
        v_debtor_id
    );

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate
    )
    VALUES (
        p_company_id,
        v_journal_id,
        v_revenue,
        2,
        CONCAT('Hotel revenue - ', v_reservation_no),
        0,
        v_selling,
        v_currency,
        v_exchange
    );

    IF v_cost > 0 THEN

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            supplier_id
        )
        VALUES (
            p_company_id,
            v_journal_id,
            v_cost_account,
            3,
            CONCAT('Hotel cost - ', v_reservation_no),
            v_cost,
            0,
            v_currency,
            v_exchange,
            v_supplier_id
        );

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            supplier_id
        )
        VALUES (
            p_company_id,
            v_journal_id,
            v_payable,
            4,
            CONCAT('Hotel supplier payable - ', v_reservation_no),
            0,
            v_cost,
            v_currency,
            v_exchange,
            v_supplier_id
        );

    END IF;

    CALL sp_validate_journal_entry(
        p_company_id,
        v_journal_id
    );

    CALL sp_post_journal_entry(
        p_company_id,
        v_journal_id,
        p_user_id
    );

    UPDATE invoices
    SET journal_entry_id = v_journal_id,
        updated_by = p_user_id
    WHERE company_id = p_company_id
      AND id = v_invoice_id;

    INSERT INTO finance_customer_ledger (
        company_id,
        branch_id,
        customer_id,
        debtor_id,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        journal_entry_id,
        invoice_id,
        description
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_date,
        'hotel',
        p_hotel_booking_id,
        v_reservation_no,
        v_selling,
        0,
        v_currency,
        v_exchange,
        v_journal_id,
        v_invoice_id,
        CONCAT('Hotel receivable - ', v_reservation_no)
    );

    IF v_supplier_id IS NOT NULL AND v_cost > 0 THEN

        INSERT INTO finance_supplier_ledger (
            company_id,
            branch_id,
            supplier_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            invoice_id,
            description
        )
        VALUES (
            p_company_id,
            v_branch_id,
            v_supplier_id,
            v_date,
            'hotel',
            p_hotel_booking_id,
            v_reservation_no,
            0,
            v_cost,
            v_currency,
            v_exchange,
            v_journal_id,
            v_invoice_id,
            CONCAT('Hotel supplier payable - ', v_reservation_no)
        );

    END IF;

    IF v_cost > 0 THEN

        INSERT INTO finance_service_costs (
            company_id,
            branch_id,
            service_type,
            service_id,
            supplier_id,
            cost_amount,
            currency_code,
            exchange_rate,
            invoice_id,
            journal_entry_id,
            notes,
            created_by
        )
        VALUES (
            p_company_id,
            v_branch_id,
            'hotel',
            p_hotel_booking_id,
            v_supplier_id,
            v_cost,
            v_currency,
            v_exchange,
            v_invoice_id,
            v_journal_id,
            CONCAT('Automatic hotel cost - ', v_reservation_no),
            p_user_id
        );

    END IF;

    SET v_profit = v_selling - v_cost;

    INSERT INTO finance_profit_records (
        company_id,
        branch_id,
        transaction_type,
        transaction_id,
        reference_no,
        revenue_amount,
        cost_amount,
        currency_code,
        exchange_rate,
        journal_entry_id,
        created_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        'hotel',
        p_hotel_booking_id,
        v_reservation_no,
        v_selling,
        v_cost,
        v_currency,
        v_exchange,
        v_journal_id,
        p_user_id
    );

    INSERT INTO finance_transaction_links (
        company_id,
        branch_id,
        transaction_type,
        transaction_id,
        invoice_id,
        journal_entry_id,
        reference_no,
        notes,
        created_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        'hotel',
        p_hotel_booking_id,
        v_invoice_id,
        v_journal_id,
        v_reservation_no,
        'Automatic Hotel accounting link.',
        p_user_id
    );

    COMMIT;

    SELECT
        p_hotel_booking_id AS hotel_booking_id,
        v_reservation_no AS reservation_no,
        v_supplier_id AS supplier_id,
        v_invoice_id AS invoice_id,
        v_journal_id AS journal_entry_id,
        v_selling AS revenue_amount,
        v_cost AS cost_amount,
        v_profit AS gross_profit,
        'POSTED' AS accounting_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_invoice` (IN `p_company_id` BIGINT UNSIGNED, IN `p_invoice_id` BIGINT UNSIGNED, IN `p_posted_by` BIGINT UNSIGNED)   BEGIN
    DECLARE v_status VARCHAR(30);
    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_currency_code CHAR(3);
    DECLARE v_exchange_rate DECIMAL(20,8);

    DECLARE v_subtotal DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_discount DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_tax DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_total DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_paid_amount DECIMAL(20,4) DEFAULT 0.0000;

    DECLARE v_receivable_account_id BIGINT UNSIGNED;
    DECLARE v_revenue_account_id BIGINT UNSIGNED;
    DECLARE v_tax_account_id BIGINT UNSIGNED;

    DECLARE v_journal_entry_id BIGINT UNSIGNED;
    DECLARE v_existing_journal_id BIGINT UNSIGNED;

    DECLARE v_entry_no VARCHAR(100);
    DECLARE v_invoice_no VARCHAR(100);
    DECLARE v_invoice_type VARCHAR(30);
    DECLARE v_revenue_code VARCHAR(20);

    DECLARE v_invoice_date DATETIME;
    DECLARE v_due_date DATE;

    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;
    DECLARE v_year_status VARCHAR(20);
    DECLARE v_period_status VARCHAR(20);

    DECLARE v_lines INT DEFAULT 0;

    
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    
    SELECT
        status,
        branch_id,
        customer_id,
        debtor_id,
        currency_code,
        exchange_rate,
        subtotal,
        discount_amount,
        tax_amount,
        total_amount,
        paid_amount,
        invoice_no,
        invoice_type,
        invoice_date,
        due_date,
        journal_entry_id
    INTO
        v_status,
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_currency_code,
        v_exchange_rate,
        v_subtotal,
        v_discount,
        v_tax,
        v_total,
        v_paid_amount,
        v_invoice_no,
        v_invoice_type,
        v_invoice_date,
        v_due_date,
        v_existing_journal_id
    FROM invoices
    WHERE company_id = p_company_id
      AND id = p_invoice_id
    LIMIT 1
    FOR UPDATE;

    
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invoice not found';
    END IF;

    
    IF v_status <> 'issued' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Only issued invoices can be posted';
    END IF;

    
    IF v_existing_journal_id IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice already has an accounting journal';
    END IF;

    
    IF v_customer_id IS NOT NULL
       AND v_debtor_id IS NOT NULL
    THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice cannot have both customer and debtor';
    END IF;

    IF v_customer_id IS NULL
       AND v_debtor_id IS NULL
    THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice must have a customer or debtor';
    END IF;

    
    IF v_subtotal < 0
       OR v_discount < 0
       OR v_tax < 0
       OR v_total < 0
    THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice amounts cannot be negative';
    END IF;

    IF v_total <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice total must be greater than zero';
    END IF;

    IF v_exchange_rate <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invalid invoice exchange rate';
    END IF;

    IF v_invoice_date IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice date is required';
    END IF;

    
    IF v_total <>
       (v_subtotal - v_discount + v_tax)
    THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice total does not match subtotal - discount + tax';
    END IF;

    
    IF v_paid_amount <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice already has payment; post invoice before allocating payments';
    END IF;

    
    IF p_posted_by IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM users
            WHERE company_id = p_company_id
              AND id = p_posted_by
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Posting user does not belong to this company';
        END IF;

    END IF;

    
    IF v_branch_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM branches
            WHERE company_id = p_company_id
              AND id = v_branch_id
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Invoice branch does not belong to this company';
        END IF;

    END IF;

    
    IF v_customer_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM customers
            WHERE company_id = p_company_id
              AND id = v_customer_id
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Invoice customer does not belong to this company';
        END IF;

    END IF;

    IF v_debtor_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM debtors
            WHERE company_id = p_company_id
              AND id = v_debtor_id
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Invoice debtor does not belong to this company';
        END IF;

    END IF;

    
    SELECT id
    INTO v_receivable_account_id
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '1410'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_receivable_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Customer Receivables account 1410 not found';
    END IF;

    
    CASE v_invoice_type
        WHEN 'ticket' THEN
            SET v_revenue_code = '4100';

        WHEN 'umrah' THEN
            SET v_revenue_code = '4200';

        WHEN 'hotel' THEN
            SET v_revenue_code = '4300';

        WHEN 'transport' THEN
            SET v_revenue_code = '4400';

        WHEN 'visa' THEN
            SET v_revenue_code = '4500';

        WHEN 'foreign_visitor' THEN
            SET v_revenue_code = '4600';

        ELSE
            SET v_revenue_code = '4900';
    END CASE;

    
    SELECT id
    INTO v_revenue_account_id
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = v_revenue_code
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_revenue_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Required revenue account not found';
    END IF;

    
    IF v_tax > 0 THEN

        SELECT id
        INTO v_tax_account_id
        FROM finance_chart_accounts
        WHERE company_id = p_company_id
          AND account_code = '2310'
          AND allow_posting = 1
          AND status = 'active'
        LIMIT 1;

        IF v_tax_account_id IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Tax Payable account 2310 not found';
        END IF;

    END IF;

    
    SELECT
        fy.id,
        fy.status
    INTO
        v_fiscal_year_id,
        v_year_status
    FROM finance_fiscal_years fy
    WHERE fy.company_id = p_company_id
      AND DATE(v_invoice_date)
          BETWEEN fy.start_date AND fy.end_date
      AND fy.status = 'open'
    ORDER BY fy.id DESC
    LIMIT 1;

    IF v_fiscal_year_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'No open fiscal year found for invoice date';
    END IF;

    
    SELECT
        fp.id,
        fp.status
    INTO
        v_period_id,
        v_period_status
    FROM finance_periods fp
    WHERE fp.company_id = p_company_id
      AND fp.fiscal_year_id = v_fiscal_year_id
      AND DATE(v_invoice_date)
          BETWEEN fp.start_date AND fp.end_date
    ORDER BY fp.period_no
    LIMIT 1;

    IF v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'No accounting period found for invoice date';
    END IF;

    IF v_period_status <> 'open' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Accounting period for invoice date is not open';
    END IF;

    
    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'journal_entry',
        v_entry_no
    );

    
    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_entry_no,
        v_invoice_date,
        'invoice',
        p_invoice_id,
        v_invoice_no,
        CONCAT('Invoice ', v_invoice_no),
        v_currency_code,
        v_exchange_rate,
        0,
        0,
        'draft',
        p_posted_by,
        p_posted_by
    );

    SET v_journal_entry_id = LAST_INSERT_ID();

    
    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        customer_id,
        debtor_id
    )
    VALUES (
        p_company_id,
        v_journal_entry_id,
        v_receivable_account_id,
        1,
        CONCAT('Receivable - Invoice ', v_invoice_no),
        v_total,
        0,
        v_currency_code,
        v_exchange_rate,
        v_customer_id,
        v_debtor_id
    );

    
    IF (v_total - v_tax) > 0 THEN

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate
        )
        VALUES (
            p_company_id,
            v_journal_entry_id,
            v_revenue_account_id,
            2,
            CONCAT('Revenue - Invoice ', v_invoice_no),
            0,
            v_total - v_tax,
            v_currency_code,
            v_exchange_rate
        );

    END IF;

    
    IF v_tax > 0 THEN

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate
        )
        VALUES (
            p_company_id,
            v_journal_entry_id,
            v_tax_account_id,
            3,
            CONCAT('Tax - Invoice ', v_invoice_no),
            0,
            v_tax,
            v_currency_code,
            v_exchange_rate
        );

    END IF;

    
    SELECT COUNT(*)
    INTO v_lines
    FROM journal_lines
    WHERE company_id = p_company_id
      AND journal_entry_id = v_journal_entry_id;

    IF v_lines < 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice journal could not be created correctly';
    END IF;

    
    CALL sp_validate_journal_entry(
        p_company_id,
        v_journal_entry_id
    );

    
    CALL sp_post_journal_entry(
        p_company_id,
        v_journal_entry_id,
        p_posted_by
    );

    
    INSERT INTO finance_customer_ledger (
        company_id,
        branch_id,
        customer_id,
        debtor_id,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        journal_entry_id,
        invoice_id,
        description
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_invoice_date,
        'invoice',
        p_invoice_id,
        v_invoice_no,
        v_total,
        0,
        v_currency_code,
        v_exchange_rate,
        v_journal_entry_id,
        p_invoice_id,
        CONCAT('Invoice ', v_invoice_no)
    );

    
    UPDATE invoices
    SET
        journal_entry_id = v_journal_entry_id,
        paid_amount = 0,
        balance_amount = v_total,
        status = CASE
            WHEN v_due_date IS NOT NULL
             AND v_due_date < CURRENT_DATE
            THEN 'overdue'
            ELSE 'issued'
        END,
        updated_by = p_posted_by
    WHERE company_id = p_company_id
      AND id = p_invoice_id;

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invoice update failed after journal posting';
    END IF;

    
    COMMIT;

    SELECT
        p_invoice_id AS invoice_id,
        v_journal_entry_id AS journal_entry_id,
        v_entry_no AS journal_entry_no,
        v_total AS invoice_total,
        v_tax AS tax_amount,
        'posted' AS status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_journal_entry` (IN `p_company_id` BIGINT UNSIGNED, IN `p_journal_entry_id` BIGINT UNSIGNED, IN `p_posted_by` BIGINT UNSIGNED)   BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;
    DECLARE v_period_status VARCHAR(20);
    DECLARE v_year_status VARCHAR(20);
    DECLARE v_debit DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_credit DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_lines INT DEFAULT 0;

    SELECT
        status,
        branch_id,
        fiscal_year_id,
        period_id
    INTO
        v_status,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id
    FROM journal_entries
    WHERE company_id = p_company_id
      AND id = p_journal_entry_id
    LIMIT 1
    FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Journal entry not found';
    END IF;

    IF v_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only draft journal entries can be posted';
    END IF;

    IF p_posted_by IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM users
            WHERE company_id = p_company_id
              AND id = p_posted_by
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                    'Posting user does not belong to this company';
        END IF;

    END IF;

    IF v_fiscal_year_id IS NOT NULL THEN

        SELECT status
        INTO v_year_status
        FROM finance_fiscal_years
        WHERE company_id = p_company_id
          AND id = v_fiscal_year_id
        LIMIT 1;

        IF v_year_status IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Fiscal year not found';
        END IF;

        IF v_year_status <> 'open' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Fiscal year is not open';
        END IF;

    END IF;

    IF v_period_id IS NOT NULL THEN

        SELECT status
        INTO v_period_status
        FROM finance_periods
        WHERE company_id = p_company_id
          AND id = v_period_id
        LIMIT 1;

        IF v_period_status IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Accounting period not found';
        END IF;

        IF v_period_status <> 'open' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Accounting period is not open';
        END IF;

    END IF;

    SELECT
        COUNT(*),
        COALESCE(SUM(debit_amount), 0),
        COALESCE(SUM(credit_amount), 0)
    INTO
        v_lines,
        v_debit,
        v_credit
    FROM journal_lines
    WHERE company_id = p_company_id
      AND journal_entry_id = p_journal_entry_id;

    IF v_lines < 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Journal must contain at least two lines';
    END IF;

    IF v_debit <= 0 OR v_credit <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Journal must contain both debit and credit';
    END IF;

    IF v_debit <> v_credit THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Journal entry is not balanced';
    END IF;

    UPDATE journal_entries
    SET
        total_debit = v_debit,
        total_credit = v_credit,
        status = 'posted',
        posted_at = CURRENT_TIMESTAMP,
        posted_by = p_posted_by
    WHERE company_id = p_company_id
      AND id = p_journal_entry_id
      AND status = 'draft';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Journal posting failed';
    END IF;

    SELECT
        p_journal_entry_id AS journal_entry_id,
        v_debit AS total_debit,
        v_credit AS total_credit,
        'posted' AS status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_payment` (IN `p_payment_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED, IN `p_invoice_id` BIGINT UNSIGNED, IN `p_allocated_amount` DECIMAL(20,4))   main: BEGIN

    DECLARE v_company_id BIGINT UNSIGNED;
    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_payment_no VARCHAR(100);
    DECLARE v_payment_type VARCHAR(20);
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_supplier_id BIGINT UNSIGNED;
    DECLARE v_agency_id BIGINT UNSIGNED;
    DECLARE v_finance_account_id BIGINT UNSIGNED;
    DECLARE v_payment_date DATETIME;
    DECLARE v_amount DECIMAL(20,4);
    DECLARE v_currency_code CHAR(3);
    DECLARE v_exchange_rate DECIMAL(20,8);
    DECLARE v_payment_method VARCHAR(30);
    DECLARE v_reference_no VARCHAR(150);
    DECLARE v_status VARCHAR(20);

    DECLARE v_user_company BIGINT UNSIGNED;
    DECLARE v_account_company BIGINT UNSIGNED;
    DECLARE v_account_branch BIGINT UNSIGNED;
    DECLARE v_account_chart_id BIGINT UNSIGNED;

    DECLARE v_invoice_company BIGINT UNSIGNED;
    DECLARE v_invoice_total DECIMAL(20,4);
    DECLARE v_invoice_paid DECIMAL(20,4);
    DECLARE v_invoice_balance DECIMAL(20,4);
    DECLARE v_invoice_status VARCHAR(30);
    DECLARE v_invoice_customer BIGINT UNSIGNED;
    DECLARE v_invoice_debtor BIGINT UNSIGNED;
    DECLARE v_invoice_agency BIGINT UNSIGNED;
    DECLARE v_invoice_currency CHAR(3);

    DECLARE v_existing_alloc DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_total_alloc DECIMAL(20,4) DEFAULT 0.0000;

    DECLARE v_ar_account_id BIGINT UNSIGNED;
    DECLARE v_ap_account_id BIGINT UNSIGNED;

    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);

    DECLARE v_new_paid DECIMAL(20,4);
    DECLARE v_new_balance DECIMAL(20,4);
    DECLARE v_new_invoice_status VARCHAR(30);

    DECLARE v_link_exists INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    

    SELECT
        company_id,
        branch_id,
        payment_no,
        payment_type,
        customer_id,
        debtor_id,
        supplier_id,
        agency_id,
        finance_account_id,
        payment_date,
        amount,
        currency_code,
        exchange_rate,
        payment_method,
        reference_no,
        status
    INTO
        v_company_id,
        v_branch_id,
        v_payment_no,
        v_payment_type,
        v_customer_id,
        v_debtor_id,
        v_supplier_id,
        v_agency_id,
        v_finance_account_id,
        v_payment_date,
        v_amount,
        v_currency_code,
        v_exchange_rate,
        v_payment_method,
        v_reference_no,
        v_status
    FROM payments
    WHERE id = p_payment_id
      AND deleted_at IS NULL
    FOR UPDATE;

    IF v_company_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Payment not found';
    END IF;

    IF v_status <> 'draft' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only draft payments can be posted';
    END IF;

    IF v_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Payment amount must be greater than zero';
    END IF;

    IF v_exchange_rate <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Exchange rate must be greater than zero';
    END IF;


    

    SELECT company_id
    INTO v_user_company
    FROM users
    WHERE id = p_user_id
      AND deleted_at IS NULL
    LIMIT 1;

    IF v_user_company IS NULL
       OR v_user_company <> v_company_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Posting user does not belong to payment company';
    END IF;


    

    SELECT
        company_id,
        branch_id,
        chart_account_id
    INTO
        v_account_company,
        v_account_branch,
        v_account_chart_id
    FROM finance_accounts
    WHERE id = v_finance_account_id
      AND company_id = v_company_id
      AND deleted_at IS NULL
      AND status = 'active'
    LIMIT 1;

    IF v_account_company IS NULL
       OR v_account_company <> v_company_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Invalid finance account for company';
    END IF;

    IF v_branch_id IS NOT NULL
       AND v_account_branch IS NOT NULL
       AND v_branch_id <> v_account_branch THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Finance account does not belong to payment branch';
    END IF;

    IF v_account_chart_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
                'Finance account chart account not found';
    END IF;


    

    IF v_payment_type = 'receipt' THEN

        IF
            (v_customer_id IS NOT NULL) +
            (v_debtor_id IS NOT NULL) +
            (v_agency_id IS NOT NULL) <> 1
        THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Receipt must have exactly one customer, debtor or agency';
        END IF;

    ELSEIF v_payment_type = 'payment' THEN

        IF
            (v_supplier_id IS NOT NULL) +
            (v_agency_id IS NOT NULL) <> 1
        THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Payment must have exactly one supplier or agency';
        END IF;

    ELSEIF v_payment_type = 'refund' THEN

        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'Use refund/reversal engine for refund payments';

    ELSE

        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'Unsupported payment type';

    END IF;


    

    SELECT id
    INTO v_ar_account_id
    FROM finance_chart_accounts
    WHERE company_id = v_company_id
      AND account_code = '1410'
      AND allow_posting = 1
      AND status = 'active'
      AND deleted_at IS NULL
    LIMIT 1;

    IF v_ar_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'Customer receivable account 1410 not found';
    END IF;


    SELECT id
    INTO v_ap_account_id
    FROM finance_chart_accounts
    WHERE company_id = v_company_id
      AND account_code = '2110'
      AND allow_posting = 1
      AND status = 'active'
      AND deleted_at IS NULL
    LIMIT 1;

    IF v_ap_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'Supplier payable account 2110 not found';
    END IF;


    

    IF p_invoice_id IS NOT NULL THEN

        IF p_allocated_amount IS NULL
           OR p_allocated_amount <= 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Allocated amount must be greater than zero';
        END IF;


        SELECT
            company_id,
            total_amount,
            paid_amount,
            balance_amount,
            status,
            customer_id,
            debtor_id,
            agency_id,
            currency_code
        INTO
            v_invoice_company,
            v_invoice_total,
            v_invoice_paid,
            v_invoice_balance,
            v_invoice_status,
            v_invoice_customer,
            v_invoice_debtor,
            v_invoice_agency,
            v_invoice_currency
        FROM invoices
        WHERE id = p_invoice_id
          AND deleted_at IS NULL
        FOR UPDATE;


        IF v_invoice_company IS NULL
           OR v_invoice_company <> v_company_id THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Invoice does not belong to payment company';
        END IF;


        IF v_invoice_status IN ('cancelled','refunded') THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Cannot allocate payment to cancelled/refunded invoice';
        END IF;


        IF v_invoice_currency <> v_currency_code THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Payment and invoice currencies do not match';
        END IF;


        IF p_allocated_amount > v_invoice_balance THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Allocation exceeds invoice balance';
        END IF;


        IF v_customer_id IS NOT NULL
           AND v_invoice_customer IS NOT NULL
           AND v_customer_id <> v_invoice_customer THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Payment customer does not match invoice customer';
        END IF;


        IF v_debtor_id IS NOT NULL
           AND v_invoice_debtor IS NOT NULL
           AND v_debtor_id <> v_invoice_debtor THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Payment debtor does not match invoice debtor';
        END IF;


        IF v_agency_id IS NOT NULL
           AND v_invoice_agency IS NOT NULL
           AND v_agency_id <> v_invoice_agency THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Payment agency does not match invoice agency';
        END IF;


        SELECT COALESCE(SUM(allocated_amount),0)
        INTO v_existing_alloc
        FROM payment_allocations
        WHERE company_id = v_company_id
          AND payment_id = p_payment_id;


        IF v_existing_alloc + p_allocated_amount > v_amount THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Total payment allocations exceed payment amount';
        END IF;


        SELECT COALESCE(SUM(allocated_amount),0)
        INTO v_total_alloc
        FROM payment_allocations
        WHERE company_id = v_company_id
          AND invoice_id = p_invoice_id
          AND payment_id <> p_payment_id;


        IF v_total_alloc + p_allocated_amount >
           v_invoice_total THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT =
                'Invoice allocation exceeds invoice total';
        END IF;

    END IF;


    

    SELECT id
    INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id = v_company_id
      AND v_payment_date >= start_date
      AND v_payment_date < DATE_ADD(end_date, INTERVAL 1 DAY)
      AND status = 'open'
    ORDER BY id DESC
    LIMIT 1;

    IF v_fiscal_year_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'No open fiscal year for payment date';
    END IF;


    

    SELECT id
    INTO v_period_id
    FROM finance_periods
    WHERE company_id = v_company_id
      AND fiscal_year_id = v_fiscal_year_id
      AND v_payment_date >= start_date
      AND v_payment_date < DATE_ADD(end_date, INTERVAL 1 DAY)
      AND status = 'open'
    LIMIT 1;

    IF v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT =
            'No open accounting period for payment date';
    END IF;


    

    IF v_payment_no IS NULL OR v_payment_no = '' THEN

        CALL sp_next_document_number(
            v_company_id,
            v_branch_id,
            'payment',
            v_payment_no
        );

        UPDATE payments
        SET
            payment_no = v_payment_no,
            updated_by = p_user_id
        WHERE company_id = v_company_id
          AND id = p_payment_id;

    END IF;


    

    CALL sp_next_document_number(
        v_company_id,
        v_branch_id,
        'journal_entry',
        v_entry_no
    );


    

    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        created_by,
        updated_by
    )
    VALUES (
        v_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_entry_no,
        v_payment_date,
        'payment',
        p_payment_id,
        v_payment_no,
        CONCAT('Payment ',v_payment_no),
        v_currency_code,
        v_exchange_rate,
        0,
        0,
        'draft',
        p_user_id,
        p_user_id
    );

    SET v_journal_id = LAST_INSERT_ID();


    

    IF v_payment_type = 'receipt' THEN

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            customer_id,
            debtor_id,
            agency_id,
            finance_account_id
        )
        VALUES (
            v_company_id,
            v_journal_id,
            v_account_chart_id,
            1,
            CONCAT('Receipt ',v_payment_no),
            v_amount,
            0,
            v_currency_code,
            v_exchange_rate,
            NULL,
            NULL,
            NULL,
            v_finance_account_id
        );


        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            customer_id,
            debtor_id,
            agency_id,
            finance_account_id
        )
        VALUES (
            v_company_id,
            v_journal_id,
            v_ar_account_id,
            2,
            CONCAT('Receivable settlement ',v_payment_no),
            0,
            v_amount,
            v_currency_code,
            v_exchange_rate,
            v_customer_id,
            v_debtor_id,
            v_agency_id,
            NULL
        );


    

    ELSEIF v_payment_type = 'payment' THEN

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            supplier_id,
            agency_id
        )
        VALUES (
            v_company_id,
            v_journal_id,
            v_ap_account_id,
            1,
            CONCAT('Payable settlement ',v_payment_no),
            v_amount,
            0,
            v_currency_code,
            v_exchange_rate,
            v_supplier_id,
            v_agency_id
        );


        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            finance_account_id
        )
        VALUES (
            v_company_id,
            v_journal_id,
            v_account_chart_id,
            2,
            CONCAT('Cash/Bank payment ',v_payment_no),
            0,
            v_amount,
            v_currency_code,
            v_exchange_rate,
            v_finance_account_id
        );

    END IF;


    

    CALL sp_validate_journal_entry(
        v_company_id,
        v_journal_id
    );


    

    CALL sp_post_journal_entry(
        v_company_id,
        v_journal_id,
        p_user_id
    );


    

    IF p_invoice_id IS NOT NULL THEN

        INSERT INTO payment_allocations (
            company_id,
            payment_id,
            invoice_id,
            allocated_amount,
            created_by
        )
        VALUES (
            v_company_id,
            p_payment_id,
            p_invoice_id,
            p_allocated_amount,
            p_user_id
        );


        SET v_new_paid =
            v_invoice_paid + p_allocated_amount;

        SET v_new_balance =
            GREATEST(v_invoice_total - v_new_paid,0);


        IF v_new_balance = 0 THEN

            SET v_new_invoice_status = 'paid';

        ELSEIF v_new_paid > 0 THEN

            SET v_new_invoice_status = 'partially_paid';

        ELSEIF v_invoice_status = 'overdue' THEN

            SET v_new_invoice_status = 'overdue';

        ELSE

            SET v_new_invoice_status = 'issued';

        END IF;


        UPDATE invoices
        SET
            paid_amount = v_new_paid,
            balance_amount = v_new_balance,
            status = v_new_invoice_status,
            updated_by = p_user_id
        WHERE company_id = v_company_id
          AND id = p_invoice_id;

    END IF;


    

    IF v_payment_type = 'receipt' THEN

        INSERT INTO finance_customer_ledger (
            company_id,
            branch_id,
            customer_id,
            debtor_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            invoice_id,
            payment_id,
            description
        )
        VALUES (
            v_company_id,
            v_branch_id,
            v_customer_id,
            v_debtor_id,
            v_payment_date,
            'payment',
            p_payment_id,
            v_payment_no,
            0,
            v_amount,
            v_currency_code,
            v_exchange_rate,
            v_journal_id,
            p_invoice_id,
            p_payment_id,
            CONCAT(
                'Customer/debtor receipt ',
                v_payment_no
            )
        );


        IF v_agency_id IS NOT NULL THEN

            INSERT INTO finance_agency_ledger (
                company_id,
                branch_id,
                agency_id,
                entry_date,
                reference_type,
                reference_id,
                reference_no,
                debit_amount,
                credit_amount,
                currency_code,
                exchange_rate,
                journal_entry_id,
                invoice_id,
                payment_id,
                description
            )
            VALUES (
                v_company_id,
                v_branch_id,
                v_agency_id,
                v_payment_date,
                'payment',
                p_payment_id,
                v_payment_no,
                0,
                v_amount,
                v_currency_code,
                v_exchange_rate,
                v_journal_id,
                p_invoice_id,
                p_payment_id,
                CONCAT(
                    'Agency receipt ',
                    v_payment_no
                )
            );

        END IF;

    END IF;


    

    IF v_payment_type = 'payment'
       AND v_supplier_id IS NOT NULL THEN

        INSERT INTO finance_supplier_ledger (
            company_id,
            branch_id,
            supplier_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            payment_id,
            description
        )
        VALUES (
            v_company_id,
            v_branch_id,
            v_supplier_id,
            v_payment_date,
            'payment',
            p_payment_id,
            v_payment_no,
            v_amount,
            0,
            v_currency_code,
            v_exchange_rate,
            v_journal_id,
            p_payment_id,
            CONCAT(
                'Supplier payment ',
                v_payment_no
            )
        );

    END IF;


    

    IF v_payment_type = 'payment'
       AND v_agency_id IS NOT NULL THEN

        INSERT INTO finance_agency_ledger (
            company_id,
            branch_id,
            agency_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            payment_id,
            description
        )
        VALUES (
            v_company_id,
            v_branch_id,
            v_agency_id,
            v_payment_date,
            'payment',
            p_payment_id,
            v_payment_no,
            v_amount,
            0,
            v_currency_code,
            v_exchange_rate,
            v_journal_id,
            p_payment_id,
            CONCAT(
                'Agency payment ',
                v_payment_no
            )
        );

    END IF;


    

    UPDATE payments
    SET
        journal_entry_id = v_journal_id,
        status = 'posted',
        updated_by = p_user_id
    WHERE company_id = v_company_id
      AND id = p_payment_id;


    

    SELECT COUNT(*)
    INTO v_link_exists
    FROM finance_transaction_links
    WHERE company_id = v_company_id
      AND transaction_type = 'other'
      AND transaction_id = p_payment_id
      AND payment_id = p_payment_id;

    IF v_link_exists = 0 THEN

        INSERT INTO finance_transaction_links (
            company_id,
            branch_id,
            transaction_type,
            transaction_id,
            invoice_id,
            payment_id,
            journal_entry_id,
            reference_no,
            notes,
            created_by
        )
        VALUES (
            v_company_id,
            v_branch_id,
            'other',
            p_payment_id,
            p_invoice_id,
            p_payment_id,
            v_journal_id,
            v_payment_no,
            'Payment accounting link',
            p_user_id
        );

    END IF;


    

    COMMIT;


    

    SELECT
        p_payment_id AS payment_id,
        v_payment_no AS payment_no,
        v_journal_id AS journal_entry_id,
        'posted' AS status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_service` (IN `p_company_id` BIGINT UNSIGNED, IN `p_service_id` BIGINT UNSIGNED, IN `p_customer_id` BIGINT UNSIGNED, IN `p_debtor_id` BIGINT UNSIGNED, IN `p_branch_id` BIGINT UNSIGNED, IN `p_selling_amount` DECIMAL(20,4), IN `p_cost_amount` DECIMAL(20,4), IN `p_currency` CHAR(3), IN `p_exchange` DECIMAL(20,8), IN `p_description` VARCHAR(500), IN `p_user_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER main: BEGIN

    DECLARE v_invoice_id BIGINT UNSIGNED;
    DECLARE v_invoice_no VARCHAR(100);
    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);
    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;

    DECLARE v_ar BIGINT UNSIGNED;
    DECLARE v_revenue BIGINT UNSIGNED;
    DECLARE v_cost_account BIGINT UNSIGNED;
    DECLARE v_payable BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    IF (p_customer_id IS NULL AND p_debtor_id IS NULL)
       OR (p_customer_id IS NOT NULL AND p_debtor_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Service requires exactly one customer or debtor.';
    END IF;

    IF p_selling_amount < 0
       OR p_cost_amount < 0
       OR p_exchange <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Invalid service financial amounts.';
    END IF;

    SELECT id INTO v_ar
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='1410'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_revenue
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='4900'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_cost_account
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='5900'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_payable
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='2110'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    IF v_ar IS NULL OR v_revenue IS NULL OR v_cost_account IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Service accounting accounts are missing.';
    END IF;

    SELECT id INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id=p_company_id
      AND CURDATE() BETWEEN start_date AND end_date
      AND status='open'
    LIMIT 1;

    SELECT id INTO v_period_id
    FROM finance_periods
    WHERE company_id=p_company_id
      AND fiscal_year_id=v_fiscal_year_id
      AND CURDATE() BETWEEN start_date AND end_date
      AND status='open'
    LIMIT 1;

    IF v_fiscal_year_id IS NULL OR v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No open finance period.';
    END IF;

    CALL sp_next_document_number(
        p_company_id,p_branch_id,'invoice',v_invoice_no
    );

    INSERT INTO invoices (
        company_id,branch_id,invoice_no,invoice_date,
        customer_id,debtor_id,currency_code,exchange_rate,
        subtotal,discount_amount,tax_amount,total_amount,
        paid_amount,balance_amount,invoice_type,status,
        notes,created_by,updated_by
    )
    VALUES (
        p_company_id,p_branch_id,v_invoice_no,CURDATE(),
        p_customer_id,p_debtor_id,p_currency,p_exchange,
        p_selling_amount,0,0,p_selling_amount,
        0,p_selling_amount,'service','issued',
        p_description,p_user_id,p_user_id
    );

    SET v_invoice_id=LAST_INSERT_ID();

    INSERT INTO invoice_items (
        company_id,invoice_id,line_no,description,
        quantity,unit_price,discount_amount,tax_amount,service_id
    )
    VALUES (
        p_company_id,v_invoice_id,1,p_description,
        1,p_selling_amount,0,0,p_service_id
    );

    CALL sp_next_document_number(
        p_company_id,p_branch_id,'journal_entry',v_entry_no
    );

    INSERT INTO journal_entries (
        company_id,branch_id,fiscal_year_id,period_id,
        entry_no,entry_date,reference_type,reference_id,
        reference_no,description,currency_code,exchange_rate,
        total_debit,total_credit,status,created_by,updated_by
    )
    VALUES (
        p_company_id,p_branch_id,v_fiscal_year_id,v_period_id,
        v_entry_no,NOW(),'service',p_service_id,
        v_invoice_no,p_description,p_currency,p_exchange,
        p_selling_amount+p_cost_amount,
        p_selling_amount+p_cost_amount,
        'draft',p_user_id,p_user_id
    );

    SET v_journal_id=LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,currency_code,
        exchange_rate,customer_id,debtor_id
    )
    VALUES (
        p_company_id,v_journal_id,v_ar,1,
        p_description,p_selling_amount,0,
        p_currency,p_exchange,p_customer_id,p_debtor_id
    );

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,currency_code,
        exchange_rate
    )
    VALUES (
        p_company_id,v_journal_id,v_revenue,2,
        p_description,0,p_selling_amount,
        p_currency,p_exchange
    );

    IF p_cost_amount>0 THEN

        INSERT INTO journal_lines (
            company_id,journal_entry_id,chart_account_id,line_no,
            description,debit_amount,credit_amount,currency_code,
            exchange_rate
        )
        VALUES (
            p_company_id,v_journal_id,v_cost_account,3,
            CONCAT('Service cost: ',p_description),
            p_cost_amount,0,p_currency,p_exchange
        );

        INSERT INTO journal_lines (
            company_id,journal_entry_id,chart_account_id,line_no,
            description,debit_amount,credit_amount,currency_code,
            exchange_rate
        )
        VALUES (
            p_company_id,v_journal_id,v_payable,4,
            CONCAT('Service payable: ',p_description),
            0,p_cost_amount,p_currency,p_exchange
        );

    END IF;

    CALL sp_validate_journal_entry(p_company_id,v_journal_id);

    CALL sp_post_journal_entry(
        p_company_id,v_journal_id,p_user_id
    );

    UPDATE invoices
    SET journal_entry_id=v_journal_id
    WHERE company_id=p_company_id
      AND id=v_invoice_id;

    INSERT INTO finance_customer_ledger (
        company_id,branch_id,customer_id,debtor_id,
        entry_date,reference_type,reference_id,reference_no,
        debit_amount,credit_amount,currency_code,exchange_rate,
        journal_entry_id,invoice_id,description
    )
    VALUES (
        p_company_id,p_branch_id,p_customer_id,p_debtor_id,
        NOW(),'service',p_service_id,v_invoice_no,
        p_selling_amount,0,p_currency,p_exchange,
        v_journal_id,v_invoice_id,p_description
    );

    SET @service_profit = p_selling_amount-p_cost_amount;

    INSERT INTO finance_profit_records (
        company_id,branch_id,transaction_type,transaction_id,
        reference_no,revenue_amount,cost_amount,currency_code,
        exchange_rate,journal_entry_id,created_by
    )
    VALUES (
        p_company_id,p_branch_id,'service',p_service_id,
        v_invoice_no,p_selling_amount,p_cost_amount,
        p_currency,p_exchange,v_journal_id,p_user_id
    );

    INSERT INTO finance_transaction_links (
        company_id,branch_id,transaction_type,transaction_id,
        invoice_id,journal_entry_id,reference_no,notes,created_by
    )
    VALUES (
        p_company_id,p_branch_id,'service',p_service_id,
        v_invoice_id,v_journal_id,v_invoice_no,
        'Automatic service accounting link.',
        p_user_id
    );

    COMMIT;

    SELECT
        v_invoice_id AS invoice_id,
        v_journal_id AS journal_entry_id,
        p_selling_amount AS revenue_amount,
        p_cost_amount AS cost_amount,
        @service_profit AS gross_profit,
        'POSTED' AS accounting_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_ticket` (IN `p_company_id` BIGINT UNSIGNED, IN `p_ticket_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER BEGIN
    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_source_id BIGINT UNSIGNED;
    DECLARE v_supplier_id BIGINT UNSIGNED;
    DECLARE v_agency_id BIGINT UNSIGNED;

    DECLARE v_ticket_no VARCHAR(100);
    DECLARE v_ticket_type VARCHAR(20);
    DECLARE v_status VARCHAR(20);
    DECLARE v_currency CHAR(3);
    DECLARE v_pnr VARCHAR(100);

    DECLARE v_reservation_date DATETIME;
    DECLARE v_departure_date DATETIME;

    DECLARE v_cost DECIMAL(20,4);
    DECLARE v_selling DECIMAL(20,4);
    DECLARE v_exchange DECIMAL(20,8);

    DECLARE v_source_type VARCHAR(20);

    DECLARE v_invoice_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_invoice_no VARCHAR(100) DEFAULT NULL;

    DECLARE v_journal_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_entry_no VARCHAR(100) DEFAULT NULL;

    DECLARE v_fiscal_year_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_period_id BIGINT UNSIGNED DEFAULT NULL;

    DECLARE v_ar_account_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_revenue_account_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_cost_account_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_payable_account_id BIGINT UNSIGNED DEFAULT NULL;

    DECLARE v_total_debit DECIMAL(20,4) DEFAULT 0;
    DECLARE v_total_credit DECIMAL(20,4) DEFAULT 0;

    DECLARE v_profit DECIMAL(20,4) DEFAULT 0;

    DECLARE v_link_exists INT DEFAULT 0;
    DECLARE v_profit_exists INT DEFAULT 0;
    DECLARE v_invoice_exists INT DEFAULT 0;

    DECLARE v_line_no INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    

    SELECT
        branch_id,
        customer_id,
        debtor_id,
        source_id,
        ticket_no,
        ticket_type,
        reservation_date,
        departure_date,
        cost_price,
        selling_price,
        currency_code,
        exchange_rate,
        status,
        pnr
    INTO
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_source_id,
        v_ticket_no,
        v_ticket_type,
        v_reservation_date,
        v_departure_date,
        v_cost,
        v_selling,
        v_currency,
        v_exchange,
        v_status,
        v_pnr
    FROM ticket_bookings
    WHERE company_id = p_company_id
      AND id = p_ticket_id
      AND deleted_at IS NULL
    FOR UPDATE;

    
    IF v_ticket_no IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket not found.';
    END IF;

    
    IF v_status <> 'issued' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Only issued tickets can be posted to accounting.';
    END IF;

    
    IF (v_customer_id IS NULL AND v_debtor_id IS NULL)
       OR (v_customer_id IS NOT NULL AND v_debtor_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket must have exactly one customer or debtor.';
    END IF;

    
    IF v_selling < 0 OR v_cost < 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket selling/cost amounts cannot be negative.';
    END IF;

    IF v_exchange <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket exchange rate must be greater than zero.';
    END IF;

    IF v_selling < v_cost THEN
        
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket selling price cannot be lower than cost price.';
    END IF;

    

    IF NOT EXISTS (
        SELECT 1
        FROM users u
        WHERE u.company_id = p_company_id
          AND u.id = p_user_id
          AND u.status = 'active'
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Posting user is invalid or inactive.';
    END IF;

    

    IF v_branch_id IS NOT NULL
       AND NOT EXISTS (
            SELECT 1
            FROM branches b
            WHERE b.company_id = p_company_id
              AND b.id = v_branch_id
              AND b.status = 'active'
       )
    THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket branch is invalid or inactive.';
    END IF;

    

    IF v_customer_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM customers c
            WHERE c.company_id = p_company_id
              AND c.id = v_customer_id
        ) THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Ticket customer does not belong to this company.';
        END IF;

    END IF;

    IF v_debtor_id IS NOT NULL THEN

        IF NOT EXISTS (
            SELECT 1
            FROM debtors d
            WHERE d.company_id = p_company_id
              AND d.id = v_debtor_id
        ) THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Ticket debtor does not belong to this company.';
        END IF;

    END IF;

    

    IF v_source_id IS NOT NULL THEN

        SELECT
            source_type,
            supplier_id,
            agency_id
        INTO
            v_source_type,
            v_supplier_id,
            v_agency_id
        FROM ticket_sources
        WHERE company_id = p_company_id
          AND id = v_source_id
        FOR UPDATE;

        IF v_source_type = 'supplier' THEN

            IF v_supplier_id IS NULL THEN
                SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Supplier ticket source has no supplier.';
            END IF;

        ELSEIF v_source_type = 'agency' THEN

            IF v_agency_id IS NULL THEN
                SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Agency ticket source has no agency.';
            END IF;

        END IF;

    END IF;

    

    SELECT COUNT(*)
    INTO v_link_exists
    FROM finance_transaction_links
    WHERE company_id = p_company_id
      AND transaction_type = 'ticket'
      AND transaction_id = p_ticket_id;

    IF v_link_exists > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'This ticket has already been posted to accounting.';
    END IF;

    SELECT COUNT(*)
    INTO v_profit_exists
    FROM finance_profit_records
    WHERE company_id = p_company_id
      AND transaction_type = 'ticket'
      AND transaction_id = p_ticket_id;

    IF v_profit_exists > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Profit record already exists for this ticket.';
    END IF;

    

    SELECT id
    INTO v_ar_account_id
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '1410'
      AND is_group = 0
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_ar_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Customer Receivables account 1410 is missing.';
    END IF;


    SELECT id
    INTO v_revenue_account_id
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '4100'
      AND is_group = 0
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_revenue_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket Revenue account 4100 is missing.';
    END IF;


    SELECT id
    INTO v_cost_account_id
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '5100'
      AND is_group = 0
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_cost_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Ticket Cost account 5100 is missing.';
    END IF;


    SELECT id
    INTO v_payable_account_id
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '2110'
      AND is_group = 0
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_payable_account_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Supplier Payables account 2110 is missing.';
    END IF;

    

    SELECT fy.id
    INTO v_fiscal_year_id
    FROM finance_fiscal_years fy
    WHERE fy.company_id = p_company_id
      AND DATE(v_reservation_date) BETWEEN fy.start_date AND fy.end_date
      AND fy.status = 'open'
    ORDER BY fy.start_date DESC
    LIMIT 1;

    IF v_fiscal_year_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No open fiscal year found for ticket date.';
    END IF;


    SELECT fp.id
    INTO v_period_id
    FROM finance_periods fp
    WHERE fp.company_id = p_company_id
      AND fp.fiscal_year_id = v_fiscal_year_id
      AND DATE(v_reservation_date) BETWEEN fp.start_date AND fp.end_date
      AND fp.status = 'open'
    ORDER BY fp.period_no
    LIMIT 1;

    IF v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No open finance period found for ticket date.';
    END IF;

    

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'invoice',
        v_invoice_no
    );

    

    INSERT INTO invoices (
        company_id,
        branch_id,
        invoice_no,
        invoice_date,
        due_date,
        customer_id,
        debtor_id,
        agency_id,
        invitation_id,
        currency_code,
        exchange_rate,
        subtotal,
        discount_amount,
        tax_amount,
        total_amount,
        paid_amount,
        balance_amount,
        journal_entry_id,
        invoice_type,
        status,
        notes,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_invoice_no,
        v_reservation_date,
        NULL,
        v_customer_id,
        v_debtor_id,
        NULL,
        NULL,
        v_currency,
        v_exchange,
        v_selling,
        0,
        0,
        v_selling,
        0,
        v_selling,
        NULL,
        'ticket',
        'issued',
        CONCAT(
            'Auto-generated from ticket ',
            v_ticket_no
        ),
        p_user_id,
        p_user_id
    );

    SET v_invoice_id = LAST_INSERT_ID();

    

    INSERT INTO invoice_items (
        company_id,
        invoice_id,
        line_no,
        service_id,
        description,
        quantity,
        unit_price,
        discount_id,
        discount_amount,
        tax_id,
        tax_amount,
        ticket_booking_id,
        umrah_booking_id,
        hotel_booking_id,
        transport_booking_id,
        visa_id
    )
    VALUES (
        p_company_id,
        v_invoice_id,
        1,
        NULL,
        CONCAT(
            'Air Ticket ',
            v_ticket_no,
            CASE
                WHEN v_pnr IS NOT NULL
                THEN CONCAT(' | PNR: ', v_pnr)
                ELSE ''
            END
        ),
        1,
        v_selling,
        NULL,
        0,
        NULL,
        0,
        p_ticket_id,
        NULL,
        NULL,
        NULL,
        NULL
    );

    

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'journal_entry',
        v_entry_no
    );

    

    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_entry_no,
        v_reservation_date,
        'ticket',
        p_ticket_id,
        v_ticket_no,
        CONCAT('Ticket accounting posting - ', v_ticket_no),
        v_currency,
        v_exchange,
        v_selling + v_cost,
        v_selling + v_cost,
        'draft',
        p_user_id,
        p_user_id
    );

    SET v_journal_id = LAST_INSERT_ID();

    

    SET v_line_no = 1;

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        customer_id,
        debtor_id,
        supplier_id,
        agency_id,
        finance_account_id
    )
    VALUES (
        p_company_id,
        v_journal_id,
        v_ar_account_id,
        v_line_no,
        CONCAT('Ticket receivable - ', v_ticket_no),
        v_selling,
        0,
        v_currency,
        v_exchange,
        v_customer_id,
        v_debtor_id,
        NULL,
        NULL,
        NULL
    );

    

    SET v_line_no = 2;

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        customer_id,
        debtor_id,
        supplier_id,
        agency_id,
        finance_account_id
    )
    VALUES (
        p_company_id,
        v_journal_id,
        v_revenue_account_id,
        v_line_no,
        CONCAT('Ticket revenue - ', v_ticket_no),
        0,
        v_selling,
        v_currency,
        v_exchange,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );

    

    IF v_cost > 0 THEN

        
        SET v_line_no = 3;

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            customer_id,
            debtor_id,
            supplier_id,
            agency_id,
            finance_account_id
        )
        VALUES (
            p_company_id,
            v_journal_id,
            v_cost_account_id,
            v_line_no,
            CONCAT('Ticket cost - ', v_ticket_no),
            v_cost,
            0,
            v_currency,
            v_exchange,
            NULL,
            NULL,
            v_supplier_id,
            v_agency_id,
            NULL
        );

        
        SET v_line_no = 4;

        INSERT INTO journal_lines (
            company_id,
            journal_entry_id,
            chart_account_id,
            line_no,
            description,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            customer_id,
            debtor_id,
            supplier_id,
            agency_id,
            finance_account_id
        )
        VALUES (
            p_company_id,
            v_journal_id,
            v_payable_account_id,
            v_line_no,
            CONCAT('Ticket source payable - ', v_ticket_no),
            0,
            v_cost,
            v_currency,
            v_exchange,
            NULL,
            NULL,
            v_supplier_id,
            v_agency_id,
            NULL
        );

    END IF;

    

    CALL sp_validate_journal_entry(
        p_company_id,
        v_journal_id
    );

    

    CALL sp_post_journal_entry(
        p_company_id,
        v_journal_id,
        p_user_id
    );

    

    UPDATE invoices
    SET journal_entry_id = v_journal_id,
        status = 'issued',
        updated_by = p_user_id
    WHERE company_id = p_company_id
      AND id = v_invoice_id;

    

    INSERT INTO finance_customer_ledger (
        company_id,
        branch_id,
        customer_id,
        debtor_id,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        journal_entry_id,
        invoice_id,
        payment_id,
        description
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_reservation_date,
        'ticket',
        p_ticket_id,
        v_ticket_no,
        v_selling,
        0,
        v_currency,
        v_exchange,
        v_journal_id,
        v_invoice_id,
        NULL,
        CONCAT('Ticket sale receivable - ', v_ticket_no)
    );

    

    IF v_supplier_id IS NOT NULL AND v_cost > 0 THEN

        INSERT INTO finance_supplier_ledger (
            company_id,
            branch_id,
            supplier_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            invoice_id,
            payment_id,
            description
        )
        VALUES (
            p_company_id,
            v_branch_id,
            v_supplier_id,
            v_reservation_date,
            'ticket',
            p_ticket_id,
            v_ticket_no,
            0,
            v_cost,
            v_currency,
            v_exchange,
            v_journal_id,
            v_invoice_id,
            NULL,
            CONCAT('Ticket supplier payable - ', v_ticket_no)
        );

    END IF;

    

    IF v_agency_id IS NOT NULL AND v_cost > 0 THEN

        INSERT INTO finance_agency_ledger (
            company_id,
            branch_id,
            agency_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            invoice_id,
            payment_id,
            description
        )
        VALUES (
            p_company_id,
            v_branch_id,
            v_agency_id,
            v_reservation_date,
            'ticket',
            p_ticket_id,
            v_ticket_no,
            0,
            v_cost,
            v_currency,
            v_exchange,
            v_journal_id,
            v_invoice_id,
            NULL,
            CONCAT('Ticket agency payable - ', v_ticket_no)
        );

    END IF;

    

    IF v_cost > 0 THEN

        INSERT INTO finance_service_costs (
            company_id,
            branch_id,
            service_type,
            service_id,
            supplier_id,
            cost_amount,
            currency_code,
            exchange_rate,
            invoice_id,
            journal_entry_id,
            notes,
            created_by
        )
        VALUES (
            p_company_id,
            v_branch_id,
            'ticket',
            p_ticket_id,
            v_supplier_id,
            v_cost,
            v_currency,
            v_exchange,
            v_invoice_id,
            v_journal_id,
            CONCAT(
                'Automatic ticket cost record. Source type: ',
                COALESCE(v_source_type, 'none')
            ),
            p_user_id
        );

    END IF;

    

    SET v_profit = v_selling - v_cost;

    INSERT INTO finance_profit_records (
        company_id,
        branch_id,
        transaction_type,
        transaction_id,
        reference_no,
        revenue_amount,
        cost_amount,
        currency_code,
        exchange_rate,
        journal_entry_id,
        created_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        'ticket',
        p_ticket_id,
        v_ticket_no,
        v_selling,
        v_cost,
        v_currency,
        v_exchange,
        v_journal_id,
        p_user_id
    );

    

    INSERT INTO finance_transaction_links (
        company_id,
        branch_id,
        transaction_type,
        transaction_id,
        invoice_id,
        payment_id,
        journal_entry_id,
        reference_no,
        notes,
        created_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        'ticket',
        p_ticket_id,
        v_invoice_id,
        NULL,
        v_journal_id,
        v_ticket_no,
        'Automatic Ticket Accounting transaction link.',
        p_user_id
    );

    

    COMMIT;

    

    SELECT
        p_ticket_id AS ticket_id,
        v_ticket_no AS ticket_no,
        v_invoice_id AS invoice_id,
        v_invoice_no AS invoice_no,
        v_journal_id AS journal_entry_id,
        v_entry_no AS journal_entry_no,
        v_selling AS revenue_amount,
        v_cost AS cost_amount,
        v_profit AS gross_profit,
        v_currency AS currency_code,
        'POSTED' AS accounting_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_transport` (IN `p_company_id` BIGINT UNSIGNED, IN `p_transport_booking_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER main: BEGIN

    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_supplier_id BIGINT UNSIGNED;

    DECLARE v_transport_no VARCHAR(100);
    DECLARE v_status VARCHAR(30);
    DECLARE v_date DATE;

    DECLARE v_cost DECIMAL(20,4);
    DECLARE v_selling DECIMAL(20,4);
    DECLARE v_currency CHAR(3);
    DECLARE v_exchange DECIMAL(20,8);
    DECLARE v_profit DECIMAL(20,4);

    DECLARE v_invoice_id BIGINT UNSIGNED;
    DECLARE v_invoice_no VARCHAR(100);
    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);

    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;

    DECLARE v_ar BIGINT UNSIGNED;
    DECLARE v_revenue BIGINT UNSIGNED;
    DECLARE v_cost_account BIGINT UNSIGNED;
    DECLARE v_payable BIGINT UNSIGNED;

    DECLARE v_exists INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        branch_id,customer_id,debtor_id,supplier_id,
        transport_no,service_date,supplier_cost,
        selling_price,currency_code,exchange_rate,status
    INTO
        v_branch_id,v_customer_id,v_debtor_id,v_supplier_id,
        v_transport_no,v_date,v_cost,
        v_selling,v_currency,v_exchange,v_status
    FROM transport_bookings
    WHERE company_id=p_company_id
      AND id=p_transport_booking_id
      AND deleted_at IS NULL
    FOR UPDATE;

    IF v_transport_no IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Transport booking not found.';
    END IF;

    IF v_status NOT IN ('confirmed','in_progress','completed') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Transport booking is not ready for accounting.';
    END IF;

    IF (v_customer_id IS NULL AND v_debtor_id IS NULL)
       OR (v_customer_id IS NOT NULL AND v_debtor_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Transport must have exactly one customer or debtor.';
    END IF;

    SELECT COUNT(*) INTO v_exists
    FROM finance_transaction_links
    WHERE company_id=p_company_id
      AND transaction_type='transport'
      AND transaction_id=p_transport_booking_id;

    IF v_exists>0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Transport booking already posted.';
    END IF;

    SELECT id INTO v_ar
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='1410'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_revenue
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='4400'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_cost_account
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='5400'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_payable
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='2110'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    IF v_ar IS NULL OR v_revenue IS NULL
       OR v_cost_account IS NULL OR
       (v_cost>0 AND v_payable IS NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Required Transport accounting accounts are missing.';
    END IF;

    IF v_cost>0 AND v_supplier_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Transport cost requires a supplier.';
    END IF;

    SELECT id INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id=p_company_id
      AND v_date BETWEEN start_date AND end_date
      AND status='open'
    LIMIT 1;

    SELECT id INTO v_period_id
    FROM finance_periods
    WHERE company_id=p_company_id
      AND fiscal_year_id=v_fiscal_year_id
      AND v_date BETWEEN start_date AND end_date
      AND status='open'
    LIMIT 1;

    IF v_fiscal_year_id IS NULL OR v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No open finance period for transport.';
    END IF;

    CALL sp_next_document_number(
        p_company_id,v_branch_id,'invoice',v_invoice_no
    );

    INSERT INTO invoices (
        company_id,branch_id,invoice_no,invoice_date,
        customer_id,debtor_id,currency_code,exchange_rate,
        subtotal,discount_amount,tax_amount,total_amount,
        paid_amount,balance_amount,invoice_type,status,
        notes,created_by,updated_by
    )
    VALUES (
        p_company_id,v_branch_id,v_invoice_no,v_date,
        v_customer_id,v_debtor_id,v_currency,v_exchange,
        v_selling,0,0,v_selling,0,v_selling,
        'transport','issued',
        CONCAT('Transport ',v_transport_no),
        p_user_id,p_user_id
    );

    SET v_invoice_id=LAST_INSERT_ID();

    INSERT INTO invoice_items (
        company_id,invoice_id,line_no,description,
        quantity,unit_price,discount_amount,tax_amount,
        transport_booking_id
    )
    VALUES (
        p_company_id,v_invoice_id,1,
        CONCAT('Transport ',v_transport_no),
        1,v_selling,0,0,p_transport_booking_id
    );

    CALL sp_next_document_number(
        p_company_id,v_branch_id,'journal_entry',v_entry_no
    );

    INSERT INTO journal_entries (
        company_id,branch_id,fiscal_year_id,period_id,
        entry_no,entry_date,reference_type,reference_id,
        reference_no,description,currency_code,exchange_rate,
        total_debit,total_credit,status,created_by,updated_by
    )
    VALUES (
        p_company_id,v_branch_id,v_fiscal_year_id,v_period_id,
        v_entry_no,v_date,'transport',p_transport_booking_id,
        v_transport_no,CONCAT('Transport accounting - ',v_transport_no),
        v_currency,v_exchange,v_selling+v_cost,v_selling+v_cost,
        'draft',p_user_id,p_user_id
    );

    SET v_journal_id=LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,currency_code,
        exchange_rate,customer_id,debtor_id
    )
    VALUES (
        p_company_id,v_journal_id,v_ar,1,
        CONCAT('Transport receivable - ',v_transport_no),
        v_selling,0,v_currency,v_exchange,
        v_customer_id,v_debtor_id
    );

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,currency_code,
        exchange_rate
    )
    VALUES (
        p_company_id,v_journal_id,v_revenue,2,
        CONCAT('Transport revenue - ',v_transport_no),
        0,v_selling,v_currency,v_exchange
    );

    IF v_cost>0 THEN

        INSERT INTO journal_lines (
            company_id,journal_entry_id,chart_account_id,line_no,
            description,debit_amount,credit_amount,currency_code,
            exchange_rate,supplier_id
        )
        VALUES (
            p_company_id,v_journal_id,v_cost_account,3,
            CONCAT('Transport cost - ',v_transport_no),
            v_cost,0,v_currency,v_exchange,v_supplier_id
        );

        INSERT INTO journal_lines (
            company_id,journal_entry_id,chart_account_id,line_no,
            description,debit_amount,credit_amount,currency_code,
            exchange_rate,supplier_id
        )
        VALUES (
            p_company_id,v_journal_id,v_payable,4,
            CONCAT('Transport supplier payable - ',v_transport_no),
            0,v_cost,v_currency,v_exchange,v_supplier_id
        );

    END IF;

    CALL sp_validate_journal_entry(p_company_id,v_journal_id);

    CALL sp_post_journal_entry(
        p_company_id,v_journal_id,p_user_id
    );

    UPDATE invoices
    SET journal_entry_id=v_journal_id,
        updated_by=p_user_id
    WHERE company_id=p_company_id
      AND id=v_invoice_id;

    INSERT INTO finance_customer_ledger (
        company_id,branch_id,customer_id,debtor_id,
        entry_date,reference_type,reference_id,reference_no,
        debit_amount,credit_amount,currency_code,exchange_rate,
        journal_entry_id,invoice_id,description
    )
    VALUES (
        p_company_id,v_branch_id,v_customer_id,v_debtor_id,
        v_date,'transport',p_transport_booking_id,v_transport_no,
        v_selling,0,v_currency,v_exchange,
        v_journal_id,v_invoice_id,
        CONCAT('Transport receivable - ',v_transport_no)
    );

    IF v_supplier_id IS NOT NULL AND v_cost>0 THEN

        INSERT INTO finance_supplier_ledger (
            company_id,branch_id,supplier_id,
            entry_date,reference_type,reference_id,reference_no,
            debit_amount,credit_amount,currency_code,exchange_rate,
            journal_entry_id,invoice_id,description
        )
        VALUES (
            p_company_id,v_branch_id,v_supplier_id,
            v_date,'transport',p_transport_booking_id,v_transport_no,
            0,v_cost,v_currency,v_exchange,
            v_journal_id,v_invoice_id,
            CONCAT('Transport supplier payable - ',v_transport_no)
        );

    END IF;

    IF v_cost>0 THEN
        INSERT INTO finance_service_costs (
            company_id,branch_id,service_type,service_id,
            supplier_id,cost_amount,currency_code,exchange_rate,
            invoice_id,journal_entry_id,notes,created_by
        )
        VALUES (
            p_company_id,v_branch_id,'transport',
            p_transport_booking_id,v_supplier_id,
            v_cost,v_currency,v_exchange,
            v_invoice_id,v_journal_id,
            CONCAT('Automatic transport cost - ',v_transport_no),
            p_user_id
        );
    END IF;

    SET v_profit=v_selling-v_cost;

    INSERT INTO finance_profit_records (
        company_id,branch_id,transaction_type,transaction_id,
        reference_no,revenue_amount,cost_amount,currency_code,
        exchange_rate,journal_entry_id,created_by
    )
    VALUES (
        p_company_id,v_branch_id,'transport',
        p_transport_booking_id,v_transport_no,
        v_selling,v_cost,v_currency,v_exchange,
        v_journal_id,p_user_id
    );

    INSERT INTO finance_transaction_links (
        company_id,branch_id,transaction_type,transaction_id,
        invoice_id,journal_entry_id,reference_no,notes,created_by
    )
    VALUES (
        p_company_id,v_branch_id,'transport',
        p_transport_booking_id,v_invoice_id,v_journal_id,
        v_transport_no,'Automatic Transport accounting link.',
        p_user_id
    );

    COMMIT;

    SELECT
        p_transport_booking_id AS transport_booking_id,
        v_transport_no AS transport_no,
        v_invoice_id AS invoice_id,
        v_journal_id AS journal_entry_id,
        v_selling AS revenue_amount,
        v_cost AS cost_amount,
        v_profit AS gross_profit,
        'POSTED' AS accounting_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_umrah` (IN `p_company_id` BIGINT UNSIGNED, IN `p_umrah_booking_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER main: BEGIN

    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_supplier_id BIGINT UNSIGNED;
    DECLARE v_agency_id BIGINT UNSIGNED;

    DECLARE v_umrah_no VARCHAR(100);
    DECLARE v_status VARCHAR(30);
    DECLARE v_source_type VARCHAR(30);

    DECLARE v_date DATE;
    DECLARE v_currency CHAR(3);
    DECLARE v_exchange DECIMAL(20,8);

    DECLARE v_cost DECIMAL(20,4);
    DECLARE v_selling DECIMAL(20,4);
    DECLARE v_profit DECIMAL(20,4);

    DECLARE v_invoice_id BIGINT UNSIGNED;
    DECLARE v_invoice_no VARCHAR(100);

    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);

    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;

    DECLARE v_ar BIGINT UNSIGNED;
    DECLARE v_revenue BIGINT UNSIGNED;
    DECLARE v_cost_account BIGINT UNSIGNED;
    DECLARE v_supplier_payable BIGINT UNSIGNED;
    DECLARE v_agency_payable BIGINT UNSIGNED;

    DECLARE v_exists INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        branch_id,
        customer_id,
        debtor_id,
        supplier_id,
        agency_id,
        umrah_no,
        source_type,
        departure_date,
        purchase_cost,
        selling_price,
        currency_code,
        exchange_rate,
        status
    INTO
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_supplier_id,
        v_agency_id,
        v_umrah_no,
        v_source_type,
        v_date,
        v_cost,
        v_selling,
        v_currency,
        v_exchange,
        v_status
    FROM umrah_bookings
    WHERE company_id = p_company_id
      AND id = p_umrah_booking_id
      AND deleted_at IS NULL
    FOR UPDATE;

    IF v_umrah_no IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Umrah booking not found.';
    END IF;

    IF v_status NOT IN ('confirmed','processing','visa_pending','visa_issued','completed') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Umrah booking is not ready for accounting.';
    END IF;

    IF (v_customer_id IS NULL AND v_debtor_id IS NULL)
       OR (v_customer_id IS NOT NULL AND v_debtor_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Umrah must have exactly one customer or debtor.';
    END IF;

    IF v_selling < 0 OR v_cost < 0 OR v_exchange <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Invalid Umrah financial amounts.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE company_id = p_company_id
          AND id = p_user_id
          AND status = 'active'
    ) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Invalid posting user.';
    END IF;

    SELECT COUNT(*)
    INTO v_exists
    FROM finance_transaction_links
    WHERE company_id = p_company_id
      AND transaction_type = 'umrah'
      AND transaction_id = p_umrah_booking_id;

    IF v_exists > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Umrah is already posted to accounting.';
    END IF;

    SELECT id INTO v_ar
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '1410'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id INTO v_revenue
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '4200'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id INTO v_cost_account
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '5200'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id INTO v_supplier_payable
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '2110'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    SELECT id INTO v_agency_payable
    FROM finance_chart_accounts
    WHERE company_id = p_company_id
      AND account_code = '2120'
      AND allow_posting = 1
      AND status = 'active'
    LIMIT 1;

    IF v_ar IS NULL OR v_revenue IS NULL OR v_cost_account IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Required Umrah accounting accounts are missing.';
    END IF;

    IF v_cost > 0 AND v_source_type = 'supplier'
       AND (v_supplier_id IS NULL OR v_supplier_payable IS NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Umrah supplier payable configuration is incomplete.';
    END IF;

    IF v_cost > 0 AND v_source_type = 'agency'
       AND (v_agency_id IS NULL OR v_agency_payable IS NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Umrah agency payable configuration is incomplete.';
    END IF;

    SELECT id INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id = p_company_id
      AND DATE(COALESCE(v_date,CURDATE()))
          BETWEEN start_date AND end_date
      AND status = 'open'
    ORDER BY start_date DESC
    LIMIT 1;

    IF v_fiscal_year_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No open fiscal year for Umrah transaction.';
    END IF;

    SELECT id INTO v_period_id
    FROM finance_periods
    WHERE company_id = p_company_id
      AND fiscal_year_id = v_fiscal_year_id
      AND DATE(COALESCE(v_date,CURDATE()))
          BETWEEN start_date AND end_date
      AND status = 'open'
    LIMIT 1;

    IF v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'No open finance period for Umrah transaction.';
    END IF;

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'invoice',
        v_invoice_no
    );

    INSERT INTO invoices (
        company_id,
        branch_id,
        invoice_no,
        invoice_date,
        due_date,
        customer_id,
        debtor_id,
        currency_code,
        exchange_rate,
        subtotal,
        discount_amount,
        tax_amount,
        total_amount,
        paid_amount,
        balance_amount,
        invoice_type,
        status,
        notes,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_invoice_no,
        COALESCE(v_date,CURDATE()),
        NULL,
        v_customer_id,
        v_debtor_id,
        v_currency,
        v_exchange,
        v_selling,
        0,
        0,
        v_selling,
        0,
        v_selling,
        'umrah',
        'issued',
        CONCAT('Auto-generated from Umrah ',v_umrah_no),
        p_user_id,
        p_user_id
    );

    SET v_invoice_id = LAST_INSERT_ID();

    INSERT INTO invoice_items (
        company_id,
        invoice_id,
        line_no,
        description,
        quantity,
        unit_price,
        discount_amount,
        tax_amount,
        umrah_booking_id
    )
    VALUES (
        p_company_id,
        v_invoice_id,
        1,
        CONCAT('Umrah Package ',v_umrah_no),
        1,
        v_selling,
        0,
        0,
        p_umrah_booking_id
    );

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'journal_entry',
        v_entry_no
    );

    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        created_by,
        updated_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_entry_no,
        COALESCE(v_date,CURDATE()),
        'umrah',
        p_umrah_booking_id,
        v_umrah_no,
        CONCAT('Umrah accounting - ',v_umrah_no),
        v_currency,
        v_exchange,
        v_selling + v_cost,
        v_selling + v_cost,
        'draft',
        p_user_id,
        p_user_id
    );

    SET v_journal_id = LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,
        currency_code,exchange_rate,customer_id,debtor_id
    )
    VALUES (
        p_company_id,v_journal_id,v_ar,1,
        CONCAT('Umrah receivable - ',v_umrah_no),
        v_selling,0,v_currency,v_exchange,
        v_customer_id,v_debtor_id
    );

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,
        currency_code,exchange_rate
    )
    VALUES (
        p_company_id,v_journal_id,v_revenue,2,
        CONCAT('Umrah revenue - ',v_umrah_no),
        0,v_selling,v_currency,v_exchange
    );

    IF v_cost > 0 THEN

        INSERT INTO journal_lines (
            company_id,journal_entry_id,chart_account_id,line_no,
            description,debit_amount,credit_amount,
            currency_code,exchange_rate,supplier_id,agency_id
        )
        VALUES (
            p_company_id,v_journal_id,v_cost_account,3,
            CONCAT('Umrah direct cost - ',v_umrah_no),
            v_cost,0,v_currency,v_exchange,
            v_supplier_id,v_agency_id
        );

        IF v_supplier_id IS NOT NULL THEN

            INSERT INTO journal_lines (
                company_id,journal_entry_id,chart_account_id,line_no,
                description,debit_amount,credit_amount,
                currency_code,exchange_rate,supplier_id
            )
            VALUES (
                p_company_id,v_journal_id,v_supplier_payable,4,
                CONCAT('Umrah supplier payable - ',v_umrah_no),
                0,v_cost,v_currency,v_exchange,v_supplier_id
            );

        ELSEIF v_agency_id IS NOT NULL THEN

            INSERT INTO journal_lines (
                company_id,journal_entry_id,chart_account_id,line_no,
                description,debit_amount,credit_amount,
                currency_code,exchange_rate,agency_id
            )
            VALUES (
                p_company_id,v_journal_id,v_agency_payable,4,
                CONCAT('Umrah agency payable - ',v_umrah_no),
                0,v_cost,v_currency,v_exchange,v_agency_id
            );

        ELSE
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Umrah cost has no supplier or agency source.';
        END IF;

    END IF;

    CALL sp_validate_journal_entry(p_company_id,v_journal_id);

    CALL sp_post_journal_entry(
        p_company_id,
        v_journal_id,
        p_user_id
    );

    UPDATE invoices
    SET journal_entry_id = v_journal_id,
        updated_by = p_user_id
    WHERE company_id = p_company_id
      AND id = v_invoice_id;

    INSERT INTO finance_customer_ledger (
        company_id,branch_id,customer_id,debtor_id,
        entry_date,reference_type,reference_id,reference_no,
        debit_amount,credit_amount,currency_code,exchange_rate,
        journal_entry_id,invoice_id,description
    )
    VALUES (
        p_company_id,v_branch_id,v_customer_id,v_debtor_id,
        COALESCE(v_date,CURDATE()),'umrah',p_umrah_booking_id,v_umrah_no,
        v_selling,0,v_currency,v_exchange,
        v_journal_id,v_invoice_id,
        CONCAT('Umrah receivable - ',v_umrah_no)
    );

    IF v_supplier_id IS NOT NULL AND v_cost > 0 THEN

        INSERT INTO finance_supplier_ledger (
            company_id,branch_id,supplier_id,
            entry_date,reference_type,reference_id,reference_no,
            debit_amount,credit_amount,currency_code,exchange_rate,
            journal_entry_id,invoice_id,description
        )
        VALUES (
            p_company_id,v_branch_id,v_supplier_id,
            COALESCE(v_date,CURDATE()),'umrah',p_umrah_booking_id,v_umrah_no,
            0,v_cost,v_currency,v_exchange,
            v_journal_id,v_invoice_id,
            CONCAT('Umrah supplier payable - ',v_umrah_no)
        );

    ELSEIF v_agency_id IS NOT NULL AND v_cost > 0 THEN

        INSERT INTO finance_agency_ledger (
            company_id,branch_id,agency_id,
            entry_date,reference_type,reference_id,reference_no,
            debit_amount,credit_amount,currency_code,exchange_rate,
            journal_entry_id,invoice_id,description
        )
        VALUES (
            p_company_id,v_branch_id,v_agency_id,
            COALESCE(v_date,CURDATE()),'umrah',p_umrah_booking_id,v_umrah_no,
            0,v_cost,v_currency,v_exchange,
            v_journal_id,v_invoice_id,
            CONCAT('Umrah agency payable - ',v_umrah_no)
        );

    END IF;

    IF v_cost > 0 THEN
        INSERT INTO finance_service_costs (
            company_id,branch_id,service_type,service_id,
            supplier_id,cost_amount,currency_code,exchange_rate,
            invoice_id,journal_entry_id,notes,created_by
        )
        VALUES (
            p_company_id,v_branch_id,'umrah',p_umrah_booking_id,
            v_supplier_id,v_cost,v_currency,v_exchange,
            v_invoice_id,v_journal_id,
            CONCAT('Automatic Umrah cost - ',v_umrah_no),
            p_user_id
        );
    END IF;

    SET v_profit = v_selling - v_cost;

    INSERT INTO finance_profit_records (
        company_id,branch_id,transaction_type,transaction_id,
        reference_no,revenue_amount,cost_amount,currency_code,
        exchange_rate,journal_entry_id,created_by
    )
    VALUES (
        p_company_id,v_branch_id,'umrah',p_umrah_booking_id,
        v_umrah_no,v_selling,v_cost,v_currency,
        v_exchange,v_journal_id,p_user_id
    );

    INSERT INTO finance_transaction_links (
        company_id,branch_id,transaction_type,transaction_id,
        invoice_id,journal_entry_id,reference_no,notes,created_by
    )
    VALUES (
        p_company_id,v_branch_id,'umrah',p_umrah_booking_id,
        v_invoice_id,v_journal_id,v_umrah_no,
        'Automatic Umrah accounting link.',
        p_user_id
    );

    COMMIT;

    SELECT
        p_umrah_booking_id AS umrah_booking_id,
        v_umrah_no AS umrah_no,
        v_invoice_id AS invoice_id,
        v_journal_id AS journal_entry_id,
        v_selling AS revenue_amount,
        v_cost AS cost_amount,
        v_profit AS gross_profit,
        'POSTED' AS accounting_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_post_visa` (IN `p_company_id` BIGINT UNSIGNED, IN `p_visa_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER main: BEGIN

    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;
    DECLARE v_supplier_id BIGINT UNSIGNED;
    DECLARE v_agency_id BIGINT UNSIGNED;

    DECLARE v_visa_no VARCHAR(100);
    DECLARE v_status VARCHAR(30);
    DECLARE v_source_type VARCHAR(30);
    DECLARE v_date DATE;

    DECLARE v_cost DECIMAL(20,4);
    DECLARE v_selling DECIMAL(20,4);
    DECLARE v_currency CHAR(3);
    DECLARE v_exchange DECIMAL(20,8);
    DECLARE v_profit DECIMAL(20,4);

    DECLARE v_invoice_id BIGINT UNSIGNED;
    DECLARE v_invoice_no VARCHAR(100);
    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);
    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;

    DECLARE v_ar BIGINT UNSIGNED;
    DECLARE v_revenue BIGINT UNSIGNED;
    DECLARE v_cost_account BIGINT UNSIGNED;
    DECLARE v_supplier_payable BIGINT UNSIGNED;
    DECLARE v_agency_payable BIGINT UNSIGNED;

    DECLARE v_exists INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        branch_id,customer_id,debtor_id,
        supplier_id,agency_id,
        visa_no,source_type,issue_date,
        purchase_cost,selling_price,
        currency_code,exchange_rate,status
    INTO
        v_branch_id,v_customer_id,v_debtor_id,
        v_supplier_id,v_agency_id,
        v_visa_no,v_source_type,v_date,
        v_cost,v_selling,
        v_currency,v_exchange,v_status
    FROM visas
    WHERE company_id=p_company_id
      AND id=p_visa_id
      AND deleted_at IS NULL
    FOR UPDATE;

    IF v_visa_no IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Visa not found.';
    END IF;

    IF v_status NOT IN ('approved','issued') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Visa is not ready for accounting.';
    END IF;

    IF (v_customer_id IS NULL AND v_debtor_id IS NULL)
       OR (v_customer_id IS NOT NULL AND v_debtor_id IS NOT NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Visa must have exactly one customer or debtor.';
    END IF;

    SELECT COUNT(*) INTO v_exists
    FROM finance_transaction_links
    WHERE company_id=p_company_id
      AND transaction_type='visa'
      AND transaction_id=p_visa_id;

    IF v_exists>0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Visa already posted.';
    END IF;

    SELECT id INTO v_ar
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='1410'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_revenue
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='4500'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_cost_account
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='5500'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_supplier_payable
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='2110'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    SELECT id INTO v_agency_payable
    FROM finance_chart_accounts
    WHERE company_id=p_company_id
      AND account_code='2120'
      AND allow_posting=1
      AND status='active'
    LIMIT 1;

    IF v_ar IS NULL OR v_revenue IS NULL OR v_cost_account IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Required Visa accounting accounts are missing.';
    END IF;

    IF v_cost>0 AND v_source_type='supplier'
       AND (v_supplier_id IS NULL OR v_supplier_payable IS NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Visa supplier payable configuration is incomplete.';
    END IF;

    IF v_cost>0 AND v_source_type='agency'
       AND (v_agency_id IS NULL OR v_agency_payable IS NULL) THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Visa agency payable configuration is incomplete.';
    END IF;

    SELECT id INTO v_fiscal_year_id
    FROM finance_fiscal_years
    WHERE company_id=p_company_id
      AND COALESCE(v_date,CURDATE())
          BETWEEN start_date AND end_date
      AND status='open'
    LIMIT 1;

    SELECT id INTO v_period_id
    FROM finance_periods
    WHERE company_id=p_company_id
      AND fiscal_year_id=v_fiscal_year_id
      AND COALESCE(v_date,CURDATE())
          BETWEEN start_date AND end_date
      AND status='open'
    LIMIT 1;

    IF v_fiscal_year_id IS NULL OR v_period_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='No open finance period for Visa.';
    END IF;

    CALL sp_next_document_number(
        p_company_id,v_branch_id,'invoice',v_invoice_no
    );

    INSERT INTO invoices (
        company_id,branch_id,invoice_no,invoice_date,
        customer_id,debtor_id,currency_code,exchange_rate,
        subtotal,discount_amount,tax_amount,total_amount,
        paid_amount,balance_amount,invoice_type,status,
        notes,created_by,updated_by
    )
    VALUES (
        p_company_id,v_branch_id,v_invoice_no,
        COALESCE(v_date,CURDATE()),
        v_customer_id,v_debtor_id,v_currency,v_exchange,
        v_selling,0,0,v_selling,0,v_selling,
        'visa','issued',
        CONCAT('Visa ',v_visa_no),
        p_user_id,p_user_id
    );

    SET v_invoice_id=LAST_INSERT_ID();

    INSERT INTO invoice_items (
        company_id,invoice_id,line_no,description,
        quantity,unit_price,discount_amount,tax_amount,visa_id
    )
    VALUES (
        p_company_id,v_invoice_id,1,
        CONCAT('Visa ',v_visa_no),
        1,v_selling,0,0,p_visa_id
    );

    CALL sp_next_document_number(
        p_company_id,v_branch_id,'journal_entry',v_entry_no
    );

    INSERT INTO journal_entries (
        company_id,branch_id,fiscal_year_id,period_id,
        entry_no,entry_date,reference_type,reference_id,
        reference_no,description,currency_code,exchange_rate,
        total_debit,total_credit,status,created_by,updated_by
    )
    VALUES (
        p_company_id,v_branch_id,v_fiscal_year_id,v_period_id,
        v_entry_no,COALESCE(v_date,CURDATE()),
        'visa',p_visa_id,v_visa_no,
        CONCAT('Visa accounting - ',v_visa_no),
        v_currency,v_exchange,v_selling+v_cost,v_selling+v_cost,
        'draft',p_user_id,p_user_id
    );

    SET v_journal_id=LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,currency_code,
        exchange_rate,customer_id,debtor_id
    )
    VALUES (
        p_company_id,v_journal_id,v_ar,1,
        CONCAT('Visa receivable - ',v_visa_no),
        v_selling,0,v_currency,v_exchange,
        v_customer_id,v_debtor_id
    );

    INSERT INTO journal_lines (
        company_id,journal_entry_id,chart_account_id,line_no,
        description,debit_amount,credit_amount,currency_code,
        exchange_rate
    )
    VALUES (
        p_company_id,v_journal_id,v_revenue,2,
        CONCAT('Visa revenue - ',v_visa_no),
        0,v_selling,v_currency,v_exchange
    );

    IF v_cost>0 THEN

        INSERT INTO journal_lines (
            company_id,journal_entry_id,chart_account_id,line_no,
            description,debit_amount,credit_amount,currency_code,
            exchange_rate,supplier_id,agency_id
        )
        VALUES (
            p_company_id,v_journal_id,v_cost_account,3,
            CONCAT('Visa cost - ',v_visa_no),
            v_cost,0,v_currency,v_exchange,
            v_supplier_id,v_agency_id
        );

        IF v_supplier_id IS NOT NULL THEN

            INSERT INTO journal_lines (
                company_id,journal_entry_id,chart_account_id,line_no,
                description,debit_amount,credit_amount,
                currency_code,exchange_rate,supplier_id
            )
            VALUES (
                p_company_id,v_journal_id,v_supplier_payable,4,
                CONCAT('Visa supplier payable - ',v_visa_no),
                0,v_cost,v_currency,v_exchange,v_supplier_id
            );

        ELSEIF v_agency_id IS NOT NULL THEN

            INSERT INTO journal_lines (
                company_id,journal_entry_id,chart_account_id,line_no,
                description,debit_amount,credit_amount,
                currency_code,exchange_rate,agency_id
            )
            VALUES (
                p_company_id,v_journal_id,v_agency_payable,4,
                CONCAT('Visa agency payable - ',v_visa_no),
                0,v_cost,v_currency,v_exchange,v_agency_id
            );

        ELSE
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT='Visa cost has no supplier or agency.';
        END IF;

    END IF;

    CALL sp_validate_journal_entry(p_company_id,v_journal_id);

    CALL sp_post_journal_entry(
        p_company_id,v_journal_id,p_user_id
    );

    UPDATE invoices
    SET journal_entry_id=v_journal_id,
        updated_by=p_user_id
    WHERE company_id=p_company_id
      AND id=v_invoice_id;

    INSERT INTO finance_customer_ledger (
        company_id,branch_id,customer_id,debtor_id,
        entry_date,reference_type,reference_id,reference_no,
        debit_amount,credit_amount,currency_code,exchange_rate,
        journal_entry_id,invoice_id,description
    )
    VALUES (
        p_company_id,v_branch_id,v_customer_id,v_debtor_id,
        COALESCE(v_date,CURDATE()),'visa',p_visa_id,v_visa_no,
        v_selling,0,v_currency,v_exchange,
        v_journal_id,v_invoice_id,
        CONCAT('Visa receivable - ',v_visa_no)
    );

    IF v_supplier_id IS NOT NULL AND v_cost>0 THEN

        INSERT INTO finance_supplier_ledger (
            company_id,branch_id,supplier_id,
            entry_date,reference_type,reference_id,reference_no,
            debit_amount,credit_amount,currency_code,exchange_rate,
            journal_entry_id,invoice_id,description
        )
        VALUES (
            p_company_id,v_branch_id,v_supplier_id,
            COALESCE(v_date,CURDATE()),'visa',p_visa_id,v_visa_no,
            0,v_cost,v_currency,v_exchange,
            v_journal_id,v_invoice_id,
            CONCAT('Visa supplier payable - ',v_visa_no)
        );

    ELSEIF v_agency_id IS NOT NULL AND v_cost>0 THEN

        INSERT INTO finance_agency_ledger (
            company_id,branch_id,agency_id,
            entry_date,reference_type,reference_id,reference_no,
            debit_amount,credit_amount,currency_code,exchange_rate,
            journal_entry_id,invoice_id,description
        )
        VALUES (
            p_company_id,v_branch_id,v_agency_id,
            COALESCE(v_date,CURDATE()),'visa',p_visa_id,v_visa_no,
            0,v_cost,v_currency,v_exchange,
            v_journal_id,v_invoice_id,
            CONCAT('Visa agency payable - ',v_visa_no)
        );

    END IF;

    IF v_cost>0 THEN
        INSERT INTO finance_service_costs (
            company_id,branch_id,service_type,service_id,
            supplier_id,cost_amount,currency_code,exchange_rate,
            invoice_id,journal_entry_id,notes,created_by
        )
        VALUES (
            p_company_id,v_branch_id,'visa',p_visa_id,
            v_supplier_id,v_cost,v_currency,v_exchange,
            v_invoice_id,v_journal_id,
            CONCAT('Automatic visa cost - ',v_visa_no),
            p_user_id
        );
    END IF;

    SET v_profit=v_selling-v_cost;

    INSERT INTO finance_profit_records (
        company_id,branch_id,transaction_type,transaction_id,
        reference_no,revenue_amount,cost_amount,currency_code,
        exchange_rate,journal_entry_id,created_by
    )
    VALUES (
        p_company_id,v_branch_id,'visa',p_visa_id,
        v_visa_no,v_selling,v_cost,v_currency,
        v_exchange,v_journal_id,p_user_id
    );

    INSERT INTO finance_transaction_links (
        company_id,branch_id,transaction_type,transaction_id,
        invoice_id,journal_entry_id,reference_no,notes,created_by
    )
    VALUES (
        p_company_id,v_branch_id,'visa',p_visa_id,
        v_invoice_id,v_journal_id,v_visa_no,
        'Automatic Visa accounting link.',p_user_id
    );

    COMMIT;

    SELECT
        p_visa_id AS visa_id,
        v_visa_no AS visa_no,
        v_invoice_id AS invoice_id,
        v_journal_id AS journal_entry_id,
        v_selling AS revenue_amount,
        v_cost AS cost_amount,
        v_profit AS gross_profit,
        'POSTED' AS accounting_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_refund_invoice` (IN `p_company_id` BIGINT UNSIGNED, IN `p_invoice_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED, IN `p_reason` TEXT)  SQL SECURITY INVOKER main: BEGIN

    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_customer_id BIGINT UNSIGNED;
    DECLARE v_debtor_id BIGINT UNSIGNED;

    DECLARE v_invoice_no VARCHAR(100);
    DECLARE v_invoice_type VARCHAR(30);

    DECLARE v_status VARCHAR(30);
    DECLARE v_journal_id BIGINT UNSIGNED;
    DECLARE v_reversal_id BIGINT UNSIGNED;

    DECLARE v_total DECIMAL(20,4);
    DECLARE v_refund_amount DECIMAL(20,4);

    DECLARE v_currency CHAR(3);
    DECLARE v_exchange DECIMAL(20,8);

    DECLARE v_refund_no VARCHAR(100);
    DECLARE v_refund_id BIGINT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        branch_id,
        customer_id,
        debtor_id,
        invoice_no,
        invoice_type,
        status,
        journal_entry_id,
        total_amount,
        paid_amount,
        currency_code,
        exchange_rate
    INTO
        v_branch_id,
        v_customer_id,
        v_debtor_id,
        v_invoice_no,
        v_invoice_type,
        v_status,
        v_journal_id,
        v_total,
        v_refund_amount,
        v_currency,
        v_exchange
    FROM invoices
    WHERE company_id = p_company_id
      AND id = p_invoice_id
    FOR UPDATE;

    IF v_invoice_no IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Invoice not found.';
    END IF;

    IF v_status IN ('cancelled','refunded') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Invoice is already cancelled or refunded.';
    END IF;

    IF v_journal_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Invoice has no posted journal.';
    END IF;

    IF v_refund_amount <= 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Nothing is available for refund.';
    END IF;

    SELECT COUNT(*)
    INTO @existing_refund_count
    FROM finance_refunds
    WHERE company_id = p_company_id
      AND invoice_id = p_invoice_id
      AND status IN ('approved','posted');

    IF @existing_refund_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='A posted refund already exists for this invoice.';
    END IF;

    CALL sp_reverse_journal_entry(
        v_journal_id,
        p_user_id,
        p_reason
    );

    SELECT id
    INTO v_reversal_id
    FROM journal_entries
    WHERE company_id = p_company_id
      AND reversal_of_id = v_journal_id
    ORDER BY id DESC
    LIMIT 1;

    IF v_reversal_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT='Refund reversal journal was not created.';
    END IF;

    CALL sp_next_document_number(
        p_company_id,
        v_branch_id,
        'refund',
        v_refund_no
    );

    INSERT INTO finance_refunds (
        company_id,
        branch_id,
        refund_no,
        invoice_id,
        customer_id,
        debtor_id,
        refund_date,
        amount,
        currency_code,
        exchange_rate,
        reason,
        journal_entry_id,
        status,
        created_by
    )
    VALUES (
        p_company_id,
        v_branch_id,
        v_refund_no,
        p_invoice_id,
        v_customer_id,
        v_debtor_id,
        NOW(),
        v_refund_amount,
        v_currency,
        v_exchange,
        COALESCE(p_reason,'Invoice refund'),
        v_reversal_id,
        'posted',
        p_user_id
    );

    SET v_refund_id = LAST_INSERT_ID();

    UPDATE invoices
    SET status = 'refunded',
        balance_amount = 0,
        updated_by = p_user_id
    WHERE company_id = p_company_id
      AND id = p_invoice_id;

    IF v_customer_id IS NOT NULL
       OR v_debtor_id IS NOT NULL THEN

        INSERT INTO finance_customer_ledger (
            company_id,
            branch_id,
            customer_id,
            debtor_id,
            entry_date,
            reference_type,
            reference_id,
            reference_no,
            debit_amount,
            credit_amount,
            currency_code,
            exchange_rate,
            journal_entry_id,
            invoice_id,
            description
        )
        VALUES (
            p_company_id,
            v_branch_id,
            v_customer_id,
            v_debtor_id,
            NOW(),
            'refund',
            v_refund_id,
            v_refund_no,
            0,
            v_refund_amount,
            v_currency,
            v_exchange,
            v_reversal_id,
            p_invoice_id,
            COALESCE(p_reason,'Invoice refund')
        );

    END IF;

    COMMIT;

    SELECT
        v_refund_id AS refund_id,
        v_refund_no AS refund_no,
        p_invoice_id AS invoice_id,
        v_invoice_no AS invoice_no,
        v_journal_id AS original_journal_id,
        v_reversal_id AS reversal_journal_id,
        v_refund_amount AS refund_amount,
        'POSTED' AS refund_status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_reverse_journal_entry` (IN `p_journal_entry_id` BIGINT UNSIGNED, IN `p_user_id` BIGINT UNSIGNED, IN `p_reason` TEXT)   main: BEGIN

    DECLARE v_company_id BIGINT UNSIGNED;
    DECLARE v_branch_id BIGINT UNSIGNED;
    DECLARE v_fiscal_year_id BIGINT UNSIGNED;
    DECLARE v_period_id BIGINT UNSIGNED;
    DECLARE v_currency_code CHAR(3);
    DECLARE v_exchange_rate DECIMAL(20,8);
    DECLARE v_status VARCHAR(20);
    DECLARE v_reversal_id BIGINT UNSIGNED;
    DECLARE v_entry_no VARCHAR(100);
    DECLARE v_reversal_no VARCHAR(100);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        currency_code,
        exchange_rate,
        status
    INTO
        v_company_id,
        v_branch_id,
        v_fiscal_year_id,
        v_period_id,
        v_currency_code,
        v_exchange_rate,
        v_status
    FROM journal_entries
    WHERE id = p_journal_entry_id
    FOR UPDATE;

    IF v_company_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Journal entry not found';
    END IF;

    IF v_status <> 'posted' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Only posted journal entries can be reversed';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM users
        WHERE id = p_user_id
          AND company_id = v_company_id
          AND deleted_at IS NULL
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid reversal user';
    END IF;

    SELECT entry_no
    INTO v_entry_no
    FROM journal_entries
    WHERE id = p_journal_entry_id;

    CALL sp_next_document_number(
        v_company_id,
        v_branch_id,
        'journal_entry',
        v_reversal_no
    );

    INSERT INTO journal_entries (
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        entry_no,
        entry_date,
        reference_type,
        reference_id,
        reference_no,
        description,
        currency_code,
        exchange_rate,
        total_debit,
        total_credit,
        status,
        reversal_of_id,
        created_by,
        updated_by
    )
    SELECT
        company_id,
        branch_id,
        fiscal_year_id,
        period_id,
        v_reversal_no,
        NOW(),
        'reversal',
        id,
        entry_no,
        CONCAT('Reversal of ',entry_no,': ',COALESCE(p_reason,'')),
        currency_code,
        exchange_rate,
        total_credit,
        total_debit,
        'draft',
        id,
        p_user_id,
        p_user_id
    FROM journal_entries
    WHERE id = p_journal_entry_id;

    SET v_reversal_id = LAST_INSERT_ID();

    INSERT INTO journal_lines (
        company_id,
        journal_entry_id,
        chart_account_id,
        line_no,
        description,
        debit_amount,
        credit_amount,
        currency_code,
        exchange_rate,
        customer_id,
        debtor_id,
        supplier_id,
        agency_id,
        finance_account_id
    )
    SELECT
        company_id,
        v_reversal_id,
        chart_account_id,
        line_no,
        CONCAT('Reversal: ',COALESCE(description,'')),
        credit_amount,
        debit_amount,
        currency_code,
        exchange_rate,
        customer_id,
        debtor_id,
        supplier_id,
        agency_id,
        finance_account_id
    FROM journal_lines
    WHERE company_id = v_company_id
      AND journal_entry_id = p_journal_entry_id;

    CALL sp_validate_journal_entry(
        v_reversal_id,
        p_user_id
    );

    CALL sp_post_journal_entry(
        v_reversal_id,
        p_user_id
    );

    UPDATE journal_entries
    SET status = 'reversed',
        updated_by = p_user_id
    WHERE id = p_journal_entry_id;

    COMMIT;

    SELECT
        p_journal_entry_id AS original_journal_entry_id,
        v_reversal_id AS reversal_journal_entry_id,
        v_reversal_no AS reversal_entry_no,
        'reversed' AS status;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_tenant_security_audit` (IN `p_company_id` BIGINT UNSIGNED)  SQL SECURITY INVOKER BEGIN

    SELECT
        'CROSS_COMPANY_CUSTOMER' AS audit_name,
        COUNT(*) AS issue_count
    FROM ticket_bookings t
    LEFT JOIN customers c
      ON c.company_id=t.company_id
     AND c.id=t.customer_id
    WHERE t.company_id=p_company_id
      AND t.customer_id IS NOT NULL
      AND c.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_DEBTOR',
        COUNT(*)
    FROM ticket_bookings t
    LEFT JOIN debtors d
      ON d.company_id=t.company_id
     AND d.id=t.debtor_id
    WHERE t.company_id=p_company_id
      AND t.debtor_id IS NOT NULL
      AND d.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_UMRAH_CUSTOMER',
        COUNT(*)
    FROM umrah_bookings u
    LEFT JOIN customers c
      ON c.company_id=u.company_id
     AND c.id=u.customer_id
    WHERE u.company_id=p_company_id
      AND u.customer_id IS NOT NULL
      AND c.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_UMRAH_DEBTOR',
        COUNT(*)
    FROM umrah_bookings u
    LEFT JOIN debtors d
      ON d.company_id=u.company_id
     AND d.id=u.debtor_id
    WHERE u.company_id=p_company_id
      AND u.debtor_id IS NOT NULL
      AND d.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_HOTEL_CUSTOMER',
        COUNT(*)
    FROM hotel_bookings h
    LEFT JOIN customers c
      ON c.company_id=h.company_id
     AND c.id=h.customer_id
    WHERE h.company_id=p_company_id
      AND h.customer_id IS NOT NULL
      AND c.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_TRANSPORT_CUSTOMER',
        COUNT(*)
    FROM transport_bookings t
    LEFT JOIN customers c
      ON c.company_id=t.company_id
     AND c.id=t.customer_id
    WHERE t.company_id=p_company_id
      AND t.customer_id IS NOT NULL
      AND c.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_VISA_CUSTOMER',
        COUNT(*)
    FROM visas v
    LEFT JOIN customers c
      ON c.company_id=v.company_id
     AND c.id=v.customer_id
    WHERE v.company_id=p_company_id
      AND v.customer_id IS NOT NULL
      AND c.id IS NULL

    UNION ALL

    SELECT
        'CROSS_COMPANY_FINANCE_ACCOUNTS',
        COUNT(*)
    FROM finance_accounts fa
    LEFT JOIN companies c
      ON c.id=fa.company_id
    WHERE fa.company_id=p_company_id
      AND c.id IS NULL;

END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_validate_journal_entry` (IN `p_company_id` BIGINT UNSIGNED, IN `p_journal_entry_id` BIGINT UNSIGNED)   BEGIN
    DECLARE v_debit DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_credit DECIMAL(20,4) DEFAULT 0.0000;
    DECLARE v_lines INT DEFAULT 0;
    DECLARE v_status VARCHAR(20);

    SELECT status
      INTO v_status
      FROM journal_entries
     WHERE company_id = p_company_id
       AND id = p_journal_entry_id
     LIMIT 1;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Journal entry not found';
    END IF;

    SELECT
        COUNT(*),
        COALESCE(SUM(debit_amount),0),
        COALESCE(SUM(credit_amount),0)
      INTO
        v_lines,
        v_debit,
        v_credit
      FROM journal_lines
     WHERE company_id = p_company_id
       AND journal_entry_id = p_journal_entry_id;

    IF v_lines < 2 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Journal entry must contain at least two lines';
    END IF;

    IF v_debit <= 0 OR v_credit <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Journal must contain both debit and credit';
    END IF;

    IF v_debit <> v_credit THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Journal entry is not balanced';
    END IF;

    UPDATE journal_entries
       SET total_debit  = v_debit,
           total_credit = v_credit
     WHERE company_id = p_company_id
       AND id = p_journal_entry_id;

    SELECT
        p_journal_entry_id AS journal_entry_id,
        v_lines AS line_count,
        v_debit AS total_debit,
        v_credit AS total_credit,
        'BALANCED' AS validation_status;
END$$

CREATE DEFINER=`root`@`localhost` PROCEDURE `sp_validate_payment_allocations` (IN `p_payment_id` BIGINT UNSIGNED)   BEGIN

    SELECT
        p.id AS payment_id,
        p.payment_no,
        p.amount AS payment_amount,
        COALESCE(SUM(pa.allocated_amount),0) AS allocated_amount,
        p.amount - COALESCE(SUM(pa.allocated_amount),0) AS unallocated_amount,
        CASE
            WHEN COALESCE(SUM(pa.allocated_amount),0) <= p.amount
            THEN 'OK'
            ELSE 'ERROR'
        END AS allocation_status
    FROM payments p
    LEFT JOIN payment_allocations pa
      ON pa.company_id = p.company_id
     AND pa.payment_id = p.id
    WHERE p.id = p_payment_id
    GROUP BY
        p.id,
        p.payment_no,
        p.amount;

END$$

DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `account_mappings`
--

CREATE TABLE `account_mappings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `module` varchar(50) NOT NULL,
  `mapping_key` varchar(80) NOT NULL,
  `account_id` bigint(20) UNSIGNED NOT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `agencies`
--

CREATE TABLE `agencies` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_no` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `legal_name` varchar(190) DEFAULT NULL,
  `contact_person` varchar(190) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `website` varchar(255) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `registration_no` varchar(100) DEFAULT NULL,
  `tax_no` varchar(100) DEFAULT NULL,
  `agency_type` enum('supplier','sub_agent','corporate','partner','other') NOT NULL DEFAULT 'partner',
  `credit_limit` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `commission_rate` decimal(10,4) NOT NULL DEFAULT 0.0000,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `agencies`
--

INSERT INTO `agencies` (`id`, `company_id`, `branch_id`, `agency_no`, `name`, `legal_name`, `contact_person`, `phone`, `phone_secondary`, `whatsapp`, `email`, `website`, `country_id`, `city_id`, `address`, `registration_no`, `tax_no`, `agency_type`, `credit_limit`, `commission_rate`, `notes`, `status`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'TEST-AGN-001', 'ERP Test Agency', NULL, 'Test Contact', '0700000002', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'partner', 1000000.0000, 0.0000, NULL, 'active', 1, 1, '2026-10-02 07:14:15', '2026-10-02 07:14:15', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `airlines`
--

CREATE TABLE `airlines` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(20) NOT NULL,
  `name` varchar(190) NOT NULL,
  `logo_path` varchar(500) DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `airports`
--

CREATE TABLE `airports` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(10) NOT NULL,
  `name` varchar(190) NOT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `audit_logs`
--

CREATE TABLE `audit_logs` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED DEFAULT NULL,
  `user_id` bigint(20) UNSIGNED DEFAULT NULL,
  `action` varchar(100) NOT NULL,
  `module` varchar(100) DEFAULT NULL,
  `table_name` varchar(190) DEFAULT NULL,
  `record_id` bigint(20) UNSIGNED DEFAULT NULL,
  `old_values` longtext DEFAULT NULL,
  `new_values` longtext DEFAULT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL,
  `request_id` varchar(100) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `backup_restore_history`
--

CREATE TABLE `backup_restore_history` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED DEFAULT NULL,
  `backup_id` bigint(20) UNSIGNED NOT NULL,
  `operation` enum('restore','verify','download','delete') NOT NULL,
  `status` enum('started','completed','failed') NOT NULL DEFAULT 'started',
  `started_at` datetime NOT NULL DEFAULT current_timestamp(),
  `completed_at` datetime DEFAULT NULL,
  `error_message` text DEFAULT NULL,
  `performed_by` bigint(20) UNSIGNED DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `bookings`
--

CREATE TABLE `bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_no` varchar(80) NOT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_date` datetime NOT NULL DEFAULT current_timestamp(),
  `travel_date` date DEFAULT NULL,
  `booking_type` enum('normal','umrah','group','corporate','other') NOT NULL DEFAULT 'normal',
  `status` enum('draft','reserved','confirmed','issued','completed','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `bookings`
--

INSERT INTO `bookings` (`id`, `company_id`, `branch_id`, `booking_no`, `customer_id`, `debtor_id`, `agency_id`, `booking_date`, `travel_date`, `booking_type`, `status`, `notes`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'TEST-BKG-001', 1, NULL, 1, '2026-10-02 07:14:16', '2026-10-12', 'normal', 'issued', 'ERP End-to-End Test Booking', 1, 1, '2026-10-02 07:14:16', '2026-10-02 07:14:16', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `booking_passengers`
--

CREATE TABLE `booking_passengers` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `booking_id` bigint(20) UNSIGNED NOT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) NOT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `nationality_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `passport_expiry` date DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `passenger_type` enum('adult','child','infant') NOT NULL DEFAULT 'adult',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `booking_passengers`
--

INSERT INTO `booking_passengers` (`id`, `company_id`, `booking_id`, `customer_id`, `first_name`, `middle_name`, `last_name`, `father_name`, `gender`, `date_of_birth`, `nationality_country_id`, `passport_no`, `passport_expiry`, `phone`, `passenger_type`, `created_at`, `updated_at`) VALUES
(1, 1, 1, 1, 'ERP', 'Test', 'Passenger', 'Test Father', 'male', NULL, NULL, NULL, NULL, '0700000000', 'adult', '2026-10-02 07:14:16', '2026-10-02 07:14:16');

-- --------------------------------------------------------

--
-- Table structure for table `branches`
--

CREATE TABLE `branches` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(50) NOT NULL,
  `name` varchar(190) NOT NULL,
  `address` text DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `manager_name` varchar(190) DEFAULT NULL,
  `timezone` varchar(80) DEFAULT NULL,
  `currency_code` char(3) DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `branches`
--

INSERT INTO `branches` (`id`, `company_id`, `code`, `name`, `address`, `country_id`, `city_id`, `phone`, `email`, `manager_name`, `timezone`, `currency_code`, `status`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 'HQ-001', 'Head Office', NULL, NULL, NULL, NULL, NULL, NULL, 'Asia/Kabul', 'AFN', 'active', '2026-10-02 04:59:05', '2026-10-02 04:59:05', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `cities`
--

CREATE TABLE `cities` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `country_id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(150) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `companies`
--

CREATE TABLE `companies` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(50) NOT NULL,
  `name` varchar(190) NOT NULL,
  `legal_name` varchar(190) DEFAULT NULL,
  `slogan` varchar(255) DEFAULT NULL,
  `description` text DEFAULT NULL,
  `logo_path` varchar(500) DEFAULT NULL,
  `logo_light_path` varchar(500) DEFAULT NULL,
  `logo_dark_path` varchar(500) DEFAULT NULL,
  `favicon_path` varchar(500) DEFAULT NULL,
  `invoice_logo_path` varchar(500) DEFAULT NULL,
  `report_logo_path` varchar(500) DEFAULT NULL,
  `registration_no` varchar(100) DEFAULT NULL,
  `tax_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `website` varchar(255) DEFAULT NULL,
  `address` text DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `timezone` varchar(80) NOT NULL DEFAULT 'Asia/Kabul',
  `default_language_code` varchar(10) NOT NULL DEFAULT 'ps',
  `default_currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `date_format` varchar(30) NOT NULL DEFAULT 'Y-m-d',
  `time_format` varchar(30) NOT NULL DEFAULT 'H:i',
  `number_decimal_places` tinyint(3) UNSIGNED NOT NULL DEFAULT 2,
  `thousand_separator` varchar(5) NOT NULL DEFAULT ',',
  `decimal_separator` varchar(5) NOT NULL DEFAULT '.',
  `week_start` tinyint(3) UNSIGNED NOT NULL DEFAULT 6,
  `fiscal_year_start_month` tinyint(3) UNSIGNED NOT NULL DEFAULT 1,
  `status` enum('active','inactive','suspended') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `companies`
--

INSERT INTO `companies` (`id`, `code`, `name`, `legal_name`, `slogan`, `description`, `logo_path`, `logo_light_path`, `logo_dark_path`, `favicon_path`, `invoice_logo_path`, `report_logo_path`, `registration_no`, `tax_no`, `phone`, `whatsapp`, `email`, `website`, `address`, `country_id`, `city_id`, `timezone`, `default_language_code`, `default_currency_code`, `date_format`, `time_format`, `number_decimal_places`, `thousand_separator`, `decimal_separator`, `week_start`, `fiscal_year_start_month`, `status`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 'ALH-001', 'AL-HIJRATAZAMI TOURISM & PILGRIMAGE COMPANY', 'AL-HIJRATAZAMI TOURISM & PILGRIMAGE COMPANY', '????? ????? ???? ????', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'Asia/Kabul', 'ps', 'AFN', 'Y-m-d', 'H:i', 2, ',', '.', 6, 1, 'active', '2026-10-02 04:51:27', '2026-10-02 04:51:27', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `company_branding`
--

CREATE TABLE `company_branding` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `primary_color` varchar(20) NOT NULL DEFAULT '#061B45',
  `secondary_color` varchar(20) NOT NULL DEFAULT '#08285D',
  `accent_color` varchar(20) NOT NULL DEFAULT '#1266D6',
  `orange_color` varchar(20) NOT NULL DEFAULT '#F47B20',
  `light_orange_color` varchar(20) NOT NULL DEFAULT '#FF9A3D',
  `white_color` varchar(20) NOT NULL DEFAULT '#FFFFFF',
  `text_color` varchar(20) NOT NULL DEFAULT '#D8E4F7',
  `muted_text_color` varchar(20) NOT NULL DEFAULT '#8FA8CC',
  `sidebar_color` varchar(20) DEFAULT NULL,
  `header_color` varchar(20) DEFAULT NULL,
  `logo_path` varchar(500) DEFAULT NULL,
  `logo_light_path` varchar(500) DEFAULT NULL,
  `logo_dark_path` varchar(500) DEFAULT NULL,
  `favicon_path` varchar(500) DEFAULT NULL,
  `login_background_path` varchar(500) DEFAULT NULL,
  `login_background_color` varchar(20) DEFAULT NULL,
  `custom_css` longtext DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `company_currencies`
--

CREATE TABLE `company_currencies` (
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `currency_code` char(3) NOT NULL,
  `is_default` tinyint(1) NOT NULL DEFAULT 0,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `company_settings`
--

CREATE TABLE `company_settings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `setting_key` varchar(190) NOT NULL,
  `setting_value` longtext DEFAULT NULL,
  `is_encrypted` tinyint(1) NOT NULL DEFAULT 0,
  `description` varchar(500) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `countries`
--

CREATE TABLE `countries` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(150) NOT NULL,
  `iso2` char(2) DEFAULT NULL,
  `iso3` char(3) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `currencies`
--

CREATE TABLE `currencies` (
  `code` char(3) NOT NULL,
  `name` varchar(100) NOT NULL,
  `symbol` varchar(20) DEFAULT NULL,
  `decimal_places` tinyint(3) UNSIGNED NOT NULL DEFAULT 2,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `currencies`
--

INSERT INTO `currencies` (`code`, `name`, `symbol`, `decimal_places`, `status`) VALUES
('AED', 'UAE Dirham', '?.?', 2, 'active'),
('AFN', 'Afghan Afghani', '?', 2, 'active'),
('EUR', 'Euro', '?', 2, 'active'),
('SAR', 'Saudi Riyal', '?', 2, 'active'),
('TRY', 'Turkish Lira', '?', 2, 'active'),
('USD', 'US Dollar', '$', 2, 'active');

-- --------------------------------------------------------

--
-- Table structure for table `customers`
--

CREATE TABLE `customers` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_no` varchar(80) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `mother_name` varchar(190) DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `occupation` varchar(190) DEFAULT NULL,
  `company_name` varchar(190) DEFAULT NULL,
  `marital_status` enum('single','married','divorced','widowed') DEFAULT NULL,
  `nationality_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `customers`
--

INSERT INTO `customers` (`id`, `company_id`, `branch_id`, `customer_no`, `first_name`, `middle_name`, `last_name`, `father_name`, `mother_name`, `date_of_birth`, `gender`, `national_id`, `phone`, `phone_secondary`, `whatsapp`, `email`, `occupation`, `company_name`, `marital_status`, `nationality_country_id`, `notes`, `status`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'TEST-CUS-001', 'ERP', 'End', 'ToEnd', 'Test Father', NULL, NULL, NULL, NULL, '0700000000', NULL, '0700000000', 'test.customer@local.test', NULL, NULL, NULL, NULL, NULL, 'active', 1, NULL, '2026-10-02 07:14:14', '2026-10-02 07:14:14', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `customer_addresses`
--

CREATE TABLE `customer_addresses` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `customer_id` bigint(20) UNSIGNED NOT NULL,
  `address_type` enum('home','office','other') NOT NULL DEFAULT 'home',
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `province` varchar(150) DEFAULT NULL,
  `district` varchar(150) DEFAULT NULL,
  `village` varchar(150) DEFAULT NULL,
  `neighborhood` varchar(190) DEFAULT NULL,
  `street` varchar(190) DEFAULT NULL,
  `house_number` varchar(100) DEFAULT NULL,
  `full_address` text DEFAULT NULL,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `customer_documents`
--

CREATE TABLE `customer_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `customer_id` bigint(20) UNSIGNED NOT NULL,
  `document_type` enum('national_id','passport','visa','photo','contract','ticket','medical','other') NOT NULL,
  `document_no` varchar(150) DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `original_name` varchar(255) DEFAULT NULL,
  `mime_type` varchar(100) DEFAULT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `verification_status` enum('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `uploaded_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `debtors`
--

CREATE TABLE `debtors` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_no` varchar(80) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `occupation` varchar(190) DEFAULT NULL,
  `workplace` varchar(190) DEFAULT NULL,
  `province` varchar(150) DEFAULT NULL,
  `district` varchar(150) DEFAULT NULL,
  `village` varchar(150) DEFAULT NULL,
  `neighborhood` varchar(190) DEFAULT NULL,
  `street` varchar(190) DEFAULT NULL,
  `house_number` varchar(100) DEFAULT NULL,
  `full_address` text DEFAULT NULL,
  `credit_limit` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `debtor_addresses`
--

CREATE TABLE `debtor_addresses` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `debtor_id` bigint(20) UNSIGNED NOT NULL,
  `address_type` enum('home','office','other') NOT NULL DEFAULT 'home',
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `province` varchar(150) DEFAULT NULL,
  `district` varchar(150) DEFAULT NULL,
  `village` varchar(150) DEFAULT NULL,
  `neighborhood` varchar(190) DEFAULT NULL,
  `street` varchar(190) DEFAULT NULL,
  `house_number` varchar(100) DEFAULT NULL,
  `full_address` text DEFAULT NULL,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `debtor_guarantors`
--

CREATE TABLE `debtor_guarantors` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `debtor_id` bigint(20) UNSIGNED NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `occupation` varchar(190) DEFAULT NULL,
  `workplace` varchar(190) DEFAULT NULL,
  `relationship` varchar(100) DEFAULT NULL,
  `address` text DEFAULT NULL,
  `guarantee_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `departments`
--

CREATE TABLE `departments` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `name` varchar(150) NOT NULL,
  `code` varchar(50) DEFAULT NULL,
  `description` text DEFAULT NULL,
  `manager_employee_id` bigint(20) UNSIGNED DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `discounts`
--

CREATE TABLE `discounts` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(50) NOT NULL,
  `name` varchar(190) NOT NULL,
  `discount_type` enum('percentage','fixed') NOT NULL DEFAULT 'percentage',
  `value` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `maximum_amount` decimal(20,4) DEFAULT NULL,
  `start_date` date DEFAULT NULL,
  `end_date` date DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `drivers`
--

CREATE TABLE `drivers` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `driver_code` varchar(80) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) NOT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `license_no` varchar(150) DEFAULT NULL,
  `license_type` varchar(100) DEFAULT NULL,
  `license_expiry` date DEFAULT NULL,
  `hire_date` date DEFAULT NULL,
  `emergency_contact_name` varchar(190) DEFAULT NULL,
  `emergency_contact_phone` varchar(50) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','suspended','on_leave') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employees`
--

CREATE TABLE `employees` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `employee_no` varchar(100) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(150) DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(150) DEFAULT NULL,
  `country_code` char(2) DEFAULT NULL,
  `province` varchar(100) DEFAULT NULL,
  `district` varchar(100) DEFAULT NULL,
  `village` varchar(150) DEFAULT NULL,
  `address` text DEFAULT NULL,
  `department_id` bigint(20) UNSIGNED DEFAULT NULL,
  `position_id` bigint(20) UNSIGNED DEFAULT NULL,
  `manager_id` bigint(20) UNSIGNED DEFAULT NULL,
  `employment_type` enum('full_time','part_time','contract','temporary','intern') NOT NULL DEFAULT 'full_time',
  `joining_date` date DEFAULT NULL,
  `leaving_date` date DEFAULT NULL,
  `basic_salary` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `salary_currency` char(3) NOT NULL DEFAULT 'AFN',
  `bank_name` varchar(150) DEFAULT NULL,
  `bank_account_no` varchar(150) DEFAULT NULL,
  `emergency_contact_name` varchar(150) DEFAULT NULL,
  `emergency_contact_phone` varchar(50) DEFAULT NULL,
  `emergency_contact_relation` varchar(100) DEFAULT NULL,
  `photo_path` varchar(500) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','on_leave','terminated') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employee_attendance`
--

CREATE TABLE `employee_attendance` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `employee_id` bigint(20) UNSIGNED NOT NULL,
  `attendance_date` date NOT NULL,
  `check_in` datetime DEFAULT NULL,
  `check_out` datetime DEFAULT NULL,
  `status` enum('present','absent','late','half_day','leave','holiday') NOT NULL DEFAULT 'present',
  `worked_hours` decimal(8,2) NOT NULL DEFAULT 0.00,
  `overtime_hours` decimal(8,2) NOT NULL DEFAULT 0.00,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employee_contracts`
--

CREATE TABLE `employee_contracts` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `employee_id` bigint(20) UNSIGNED NOT NULL,
  `contract_no` varchar(100) NOT NULL,
  `contract_type` enum('permanent','temporary','contract','internship') NOT NULL DEFAULT 'permanent',
  `start_date` date NOT NULL,
  `end_date` date DEFAULT NULL,
  `salary` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `working_hours` decimal(8,2) DEFAULT NULL,
  `file_path` varchar(500) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('draft','active','expired','terminated') NOT NULL DEFAULT 'draft',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employee_documents`
--

CREATE TABLE `employee_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `employee_id` bigint(20) UNSIGNED NOT NULL,
  `document_type` enum('national_id','passport','contract','certificate','photo','medical','other') NOT NULL,
  `document_no` varchar(150) DEFAULT NULL,
  `title` varchar(200) DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `file_name` varchar(255) DEFAULT NULL,
  `mime_type` varchar(150) DEFAULT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `verified` tinyint(1) NOT NULL DEFAULT 0,
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `uploaded_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employee_leaves`
--

CREATE TABLE `employee_leaves` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `employee_id` bigint(20) UNSIGNED NOT NULL,
  `leave_type` enum('annual','sick','emergency','maternity','unpaid','other') NOT NULL,
  `start_date` date NOT NULL,
  `end_date` date NOT NULL,
  `days` decimal(8,2) NOT NULL DEFAULT 0.00,
  `reason` text DEFAULT NULL,
  `status` enum('pending','approved','rejected','cancelled') NOT NULL DEFAULT 'pending',
  `approved_by` bigint(20) UNSIGNED DEFAULT NULL,
  `approved_at` datetime DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employee_salary_payments`
--

CREATE TABLE `employee_salary_payments` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `employee_id` bigint(20) UNSIGNED NOT NULL,
  `payment_no` varchar(100) NOT NULL,
  `salary_month` date NOT NULL,
  `basic_salary` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `allowances` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `overtime_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `deductions` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `net_amount` decimal(20,4) GENERATED ALWAYS AS (`basic_salary` + `allowances` + `overtime_amount` - `deductions` - `tax_amount`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `payment_date` date DEFAULT NULL,
  `payment_method` enum('cash','bank','mobile_wallet','transfer','other') DEFAULT NULL,
  `finance_account_id` bigint(20) UNSIGNED DEFAULT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `status` enum('draft','approved','paid','cancelled') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `approved_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `employee_user_accounts`
--

CREATE TABLE `employee_user_accounts` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `employee_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `exchange_rates`
--

CREATE TABLE `exchange_rates` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `from_currency_code` char(3) NOT NULL,
  `to_currency_code` char(3) NOT NULL,
  `rate` decimal(20,8) NOT NULL,
  `effective_date` date NOT NULL,
  `source` varchar(100) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `expenses`
--

CREATE TABLE `expenses` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `expense_no` varchar(100) NOT NULL,
  `expense_date` date NOT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `expense_account_id` bigint(20) UNSIGNED NOT NULL,
  `payment_account_id` bigint(20) UNSIGNED DEFAULT NULL,
  `description` varchar(500) NOT NULL,
  `amount` decimal(20,4) NOT NULL,
  `tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `payment_status` enum('unpaid','partially_paid','paid','cancelled') NOT NULL DEFAULT 'unpaid',
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `family_members`
--

CREATE TABLE `family_members` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `customer_id` bigint(20) UNSIGNED NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `relationship` varchar(100) NOT NULL,
  `date_of_birth` date DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `finance_accounts`
--

CREATE TABLE `finance_accounts` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `chart_account_id` bigint(20) UNSIGNED NOT NULL,
  `account_no` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `account_type` enum('cash','bank','mobile_wallet','card','other') NOT NULL DEFAULT 'cash',
  `bank_name` varchar(190) DEFAULT NULL,
  `account_number` varchar(190) DEFAULT NULL,
  `iban` varchar(190) DEFAULT NULL,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `opening_balance` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_accounts`
--

INSERT INTO `finance_accounts` (`id`, `company_id`, `branch_id`, `chart_account_id`, `account_no`, `name`, `account_type`, `bank_name`, `account_number`, `iban`, `currency_code`, `opening_balance`, `status`, `notes`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 2, 'CASH-001', 'Main Cash', 'cash', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Main Head Office Cash Account', NULL, NULL, '2026-10-02 04:59:53', '2026-10-02 04:59:53', NULL),
(2, 1, 1, 3, 'BANK-001', 'Main Bank Account', 'bank', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Main Head Office Bank Account', NULL, NULL, '2026-10-02 05:00:47', '2026-10-02 05:00:47', NULL),
(3, 1, 1, 4, 'WALLET-001', 'Main Mobile Wallet', 'mobile_wallet', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Main Head Office Mobile Wallet Account', NULL, NULL, '2026-10-02 05:01:30', '2026-10-02 05:01:30', NULL),
(4, 1, 1, 79, 'AR-001', 'Customer Receivables', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Customer and Debtor Accounts Receivable', NULL, NULL, '2026-10-02 05:55:48', '2026-10-02 05:55:48', NULL),
(5, 1, 1, 80, 'AP-001', 'Supplier Payables', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Supplier and Agency Accounts Payable', NULL, NULL, '2026-10-02 05:58:34', '2026-10-02 05:58:34', NULL),
(6, 1, 1, 81, 'SALARY-001', 'Employee Salary Payable', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Outstanding employee salary payable account', NULL, NULL, '2026-10-02 06:00:07', '2026-10-02 06:00:07', NULL),
(7, 1, 1, 82, 'TAX-001', 'Tax Payable', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Taxes payable to government authorities', NULL, NULL, '2026-10-02 06:02:13', '2026-10-02 06:02:13', NULL),
(8, 1, 1, 12, 'CAPITAL-001', 'Owner Capital', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Owner capital account', NULL, NULL, '2026-10-02 06:03:02', '2026-10-02 06:03:02', NULL),
(9, 1, 1, 13, 'RE-001', 'Retained Earnings', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Retained earnings and accumulated profits', NULL, NULL, '2026-10-02 06:03:29', '2026-10-02 06:03:29', NULL),
(10, 1, 1, 15, 'REV-TICKET-001', 'Ticket Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Revenue generated from ticket sales', NULL, NULL, '2026-10-02 06:04:02', '2026-10-02 06:04:02', NULL),
(11, 1, 1, 16, 'REV-UMRAH-001', 'Umrah Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Revenue generated from Umrah services', NULL, NULL, '2026-10-02 06:04:24', '2026-10-02 06:04:24', NULL),
(12, 1, 1, 17, 'REV-HOTEL-001', 'Hotel Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Revenue generated from hotel services', NULL, NULL, '2026-10-02 06:04:44', '2026-10-02 06:04:44', NULL),
(13, 1, 1, 18, 'REV-TRANSPORT-001', 'Transport Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Revenue generated from transport services', NULL, NULL, '2026-10-02 06:05:13', '2026-10-02 06:05:13', NULL),
(14, 1, 1, 19, 'REV-VISA-001', 'Visa Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Revenue generated from visa services', NULL, NULL, '2026-10-02 06:05:34', '2026-10-02 06:05:34', NULL),
(15, 1, 1, 20, 'REV-VISITOR-001', 'Foreign Visitor Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Revenue generated from foreign visitor services', NULL, NULL, '2026-10-02 06:06:00', '2026-10-02 06:06:00', NULL),
(16, 1, 1, 21, 'REV-OTHER-001', 'Other Revenue', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Other business revenue', NULL, NULL, '2026-10-02 06:07:58', '2026-10-02 06:07:58', NULL),
(17, 1, 1, 23, 'COST-TICKET-001', 'Ticket Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Direct cost of airline and ticket services', NULL, NULL, '2026-10-02 06:08:39', '2026-10-02 06:08:39', NULL),
(18, 1, 1, 24, 'COST-UMRAH-001', 'Umrah Direct Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Direct cost of Umrah services', NULL, NULL, '2026-10-02 06:09:13', '2026-10-02 06:09:13', NULL),
(19, 1, 1, 25, 'COST-HOTEL-001', 'Hotel Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Direct cost of hotel services', NULL, NULL, '2026-10-02 06:09:49', '2026-10-02 06:09:49', NULL),
(23, 1, 1, 26, 'COST-TRANSPORT-001', 'Transport Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Direct cost of transport services', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(24, 1, 1, 27, 'COST-VISA-001', 'Visa Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Direct cost of visa services', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(25, 1, 1, 28, 'COST-VISITOR-001', 'Foreign Visitor Direct Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Direct cost of foreign visitor services', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(26, 1, 1, 29, 'COST-OTHER-001', 'Other Direct Cost', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Other direct business costs', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(27, 1, 1, 31, 'EXP-SALARY-001', 'Salaries and Wages', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Employee salaries and wages', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(28, 1, 1, 32, 'EXP-RENT-001', 'Rent Expense', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Office and branch rent', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(29, 1, 1, 33, 'EXP-UTILITIES-001', 'Utilities Expense', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Electricity, water and utilities', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(30, 1, 1, 34, 'EXP-COMMUNICATION-001', 'Internet and Communication', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Internet, telephone and communication', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(31, 1, 1, 35, 'EXP-TRANSPORT-001', 'Transportation Expense', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Internal business transportation expense', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(32, 1, 1, 36, 'EXP-MARKETING-001', 'Marketing Expense', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Marketing and advertising expenses', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(33, 1, 1, 37, 'EXP-OFFICE-001', 'Office Expense', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Office supplies and general office expenses', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(34, 1, 1, 38, 'EXP-BANK-001', 'Bank Charges', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Bank and payment processing charges', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL),
(35, 1, 1, 39, 'EXP-OTHER-001', 'Other Operating Expenses', 'other', NULL, NULL, NULL, 'AFN', 0.0000, 'active', 'Other operating expenses', NULL, NULL, '2026-10-02 06:12:38', '2026-10-02 06:12:38', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `finance_agency_ledger`
--

CREATE TABLE `finance_agency_ledger` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED NOT NULL,
  `entry_date` datetime NOT NULL DEFAULT current_timestamp(),
  `reference_type` varchar(80) NOT NULL,
  `reference_id` bigint(20) UNSIGNED NOT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `debit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `payment_id` bigint(20) UNSIGNED DEFAULT NULL,
  `description` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `finance_approvals`
--

CREATE TABLE `finance_approvals` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `document_type` varchar(80) NOT NULL,
  `document_id` bigint(20) UNSIGNED NOT NULL,
  `approval_level` tinyint(3) UNSIGNED NOT NULL DEFAULT 1,
  `status` enum('pending','approved','rejected','cancelled') NOT NULL DEFAULT 'pending',
  `requested_by` bigint(20) UNSIGNED DEFAULT NULL,
  `approved_by` bigint(20) UNSIGNED DEFAULT NULL,
  `requested_at` datetime NOT NULL DEFAULT current_timestamp(),
  `approved_at` datetime DEFAULT NULL,
  `remarks` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `finance_audit_log`
--

CREATE TABLE `finance_audit_log` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `user_id` bigint(20) UNSIGNED DEFAULT NULL,
  `action` varchar(80) NOT NULL,
  `document_type` varchar(80) DEFAULT NULL,
  `document_id` bigint(20) UNSIGNED DEFAULT NULL,
  `old_data` longtext DEFAULT NULL,
  `new_data` longtext DEFAULT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `finance_chart_accounts`
--

CREATE TABLE `finance_chart_accounts` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `parent_account_id` bigint(20) UNSIGNED DEFAULT NULL,
  `account_code` varchar(50) NOT NULL,
  `account_name` varchar(190) NOT NULL,
  `account_name_local` varchar(190) DEFAULT NULL,
  `account_type` enum('asset','liability','equity','revenue','expense') NOT NULL,
  `normal_balance` enum('debit','credit') NOT NULL,
  `level_no` tinyint(3) UNSIGNED NOT NULL DEFAULT 1,
  `is_group` tinyint(1) NOT NULL DEFAULT 0,
  `is_system` tinyint(1) NOT NULL DEFAULT 0,
  `allow_posting` tinyint(1) NOT NULL DEFAULT 1,
  `currency_code` char(3) DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `description` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_chart_accounts`
--

INSERT INTO `finance_chart_accounts` (`id`, `company_id`, `parent_account_id`, `account_code`, `account_name`, `account_name_local`, `account_type`, `normal_balance`, `level_no`, `is_group`, `is_system`, `allow_posting`, `currency_code`, `status`, `description`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, NULL, '1000', 'Assets', '?????', 'asset', 'debit', 1, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:52:34', NULL),
(2, 1, 1, '1100', 'Cash and Cash Equivalents', '???? ?? ???? ?????', 'asset', 'debit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(3, 1, 1, '1200', 'Bank Accounts', '????? ???????', 'asset', 'debit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(4, 1, 1, '1300', 'Mobile Wallets', '?????? ???????', 'asset', 'debit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(5, 1, 1, '1400', 'Accounts Receivable', '? ???????? ??????', 'asset', 'debit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(6, 1, 1, '1500', 'Other Receivables', '??? ?????? ??????? ??????', 'asset', 'debit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(7, 1, NULL, '2000', 'Liabilities', '????????? ?? ??????', 'liability', 'credit', 1, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:52:34', NULL),
(8, 1, 7, '2100', 'Accounts Payable', '? ???? ?????? ??????', 'liability', 'credit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(9, 1, 7, '2200', 'Salary Payable', '? ??????? ???? ???', 'liability', 'credit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(10, 1, 7, '2300', 'Tax Payable', '? ??????? ???? ???', 'liability', 'credit', 2, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:55:37', NULL),
(11, 1, NULL, '3000', 'Equity', '??????', 'equity', 'credit', 1, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:52:34', NULL),
(12, 1, 11, '3100', 'Owner Capital', '? ???? ??????', 'equity', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(13, 1, 11, '3200', 'Retained Earnings', '???? ??? ???', 'equity', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(14, 1, NULL, '4000', 'Revenue', '??????', 'revenue', 'credit', 1, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:52:34', NULL),
(15, 1, 14, '4100', 'Ticket Revenue', '? ?????? ????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(16, 1, 14, '4200', 'Umrah Revenue', '? ???? ????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(17, 1, 14, '4300', 'Hotel Revenue', '? ???? ????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(18, 1, 14, '4400', 'Transport Revenue', '? ????????? ????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(19, 1, 14, '4500', 'Visa Revenue', '? ???? ????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(20, 1, 14, '4600', 'Foreign Visitor Revenue', '? ?????? ???????? ????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(21, 1, 14, '4900', 'Other Revenue', '??? ??????', 'revenue', 'credit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(22, 1, NULL, '5000', 'Cost of Services', '? ?????? ?????? ?????', 'expense', 'debit', 1, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:52:34', NULL),
(23, 1, 22, '5100', 'Ticket Cost', '? ??? ?????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(24, 1, 22, '5200', 'Umrah Direct Cost', '? ???? ?????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(25, 1, 22, '5300', 'Hotel Cost', '? ???? ?????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(26, 1, 22, '5400', 'Transport Cost', '? ????????? ?????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(27, 1, 22, '5500', 'Visa Cost', '? ???? ?????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(28, 1, 22, '5600', 'Foreign Visitor Direct Cost', '? ????? ????? ?????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(29, 1, 22, '5900', 'Other Direct Cost', '??? ?????? ?????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(30, 1, NULL, '6000', 'Operating Expenses', '??????? ?????', 'expense', 'debit', 1, 1, 1, 0, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:52:34', NULL),
(31, 1, 30, '6100', 'Salaries and Wages', '??????? ?? ??????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(32, 1, 30, '6200', 'Rent Expense', '? ????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(33, 1, 30, '6300', 'Utilities Expense', '? ?????? ?? ???? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(34, 1, 30, '6400', 'Internet and Communication', '? ??????? ?? ????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(35, 1, 30, '6500', 'Transportation Expense', '? ????????? ??????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(36, 1, 30, '6600', 'Marketing Expense', '? ??????????? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(37, 1, 30, '6700', 'Office Expense', '? ???? ????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(38, 1, 30, '6800', 'Bank Charges', '????? ????? ?? ??????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(39, 1, 30, '6900', 'Other Operating Expenses', '??? ??????? ?????', 'expense', 'debit', 2, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 04:52:34', '2026-10-02 04:57:10', NULL),
(79, 1, 5, '1410', 'Customer Receivables', '? ???????? ??????', 'asset', 'debit', 3, 0, 1, 1, 'AFN', 'active', 'Receivables from customers and debtors', NULL, NULL, '2026-10-02 05:02:54', '2026-10-02 05:02:54', NULL),
(80, 1, 8, '2110', 'Supplier Payables', 'د عرضه کوونکو پورونه', 'liability', 'credit', 3, 0, 1, 1, 'AFN', 'active', 'Payables owed to suppliers and service providers', NULL, NULL, '2026-10-02 05:57:31', '2026-10-02 05:57:31', NULL),
(81, 1, 9, '2210', 'Employee Salary Payable', 'د کارمندانو معاشونه', 'liability', 'credit', 3, 0, 1, 1, 'AFN', 'active', 'Outstanding employee salary liabilities', NULL, NULL, '2026-10-02 05:59:38', '2026-10-02 05:59:38', NULL),
(82, 1, 10, '2310', 'Tax Payable', 'د مالیې پور', 'liability', 'credit', 3, 0, 1, 1, 'AFN', 'active', 'Taxes payable to government authorities', NULL, NULL, '2026-10-02 06:01:06', '2026-10-02 06:01:06', NULL),
(83, 1, 8, '2120', 'Agency Payables', 'Agency Payables', 'liability', 'credit', 3, 0, 1, 1, 'AFN', 'active', NULL, NULL, NULL, '2026-10-02 07:05:16', '2026-10-02 07:05:16', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `finance_customer_ledger`
--

CREATE TABLE `finance_customer_ledger` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `entry_date` datetime NOT NULL DEFAULT current_timestamp(),
  `reference_type` varchar(80) NOT NULL,
  `reference_id` bigint(20) UNSIGNED NOT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `debit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `payment_id` bigint(20) UNSIGNED DEFAULT NULL,
  `description` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_customer_ledger`
--

INSERT INTO `finance_customer_ledger` (`id`, `company_id`, `branch_id`, `customer_id`, `debtor_id`, `entry_date`, `reference_type`, `reference_id`, `reference_no`, `debit_amount`, `credit_amount`, `currency_code`, `exchange_rate`, `journal_entry_id`, `invoice_id`, `payment_id`, `description`, `created_at`) VALUES
(1, 1, 1, 1, NULL, '2026-10-02 07:14:16', 'ticket', 1, 'TEST-TKT-001', 1500.0000, 0.0000, 'AFN', 1.00000000, 1, 1, NULL, 'Ticket sale receivable - TEST-TKT-001', '2026-10-02 07:14:17'),
(2, 1, 1, 1, NULL, '2026-10-02 07:14:18', 'payment', 1, 'PAY-000001', 0.0000, 1500.0000, 'AFN', 1.00000000, 3, 1, 1, 'Customer/debtor receipt PAY-000001', '2026-10-02 07:16:59');

-- --------------------------------------------------------

--
-- Table structure for table `finance_fiscal_years`
--

CREATE TABLE `finance_fiscal_years` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(100) NOT NULL,
  `start_date` date NOT NULL,
  `end_date` date NOT NULL,
  `status` enum('open','closed','locked') NOT NULL DEFAULT 'open',
  `is_current` tinyint(1) NOT NULL DEFAULT 0,
  `closed_at` datetime DEFAULT NULL,
  `closed_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_fiscal_years`
--

INSERT INTO `finance_fiscal_years` (`id`, `company_id`, `name`, `start_date`, `end_date`, `status`, `is_current`, `closed_at`, `closed_by`, `created_by`, `updated_by`, `created_at`, `updated_at`) VALUES
(1, 1, 'FY-2026', '2026-01-01', '2026-12-31', 'open', 1, NULL, NULL, NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43');

-- --------------------------------------------------------

--
-- Table structure for table `finance_periods`
--

CREATE TABLE `finance_periods` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `fiscal_year_id` bigint(20) UNSIGNED NOT NULL,
  `period_no` tinyint(3) UNSIGNED NOT NULL,
  `name` varchar(100) NOT NULL,
  `start_date` date NOT NULL,
  `end_date` date NOT NULL,
  `status` enum('open','closed','locked') NOT NULL DEFAULT 'open',
  `closed_at` datetime DEFAULT NULL,
  `closed_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_periods`
--

INSERT INTO `finance_periods` (`id`, `company_id`, `fiscal_year_id`, `period_no`, `name`, `start_date`, `end_date`, `status`, `closed_at`, `closed_by`, `created_at`, `updated_at`) VALUES
(1, 1, 1, 1, 'January 2026', '2026-01-01', '2026-01-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(2, 1, 1, 2, 'February 2026', '2026-02-01', '2026-02-28', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(3, 1, 1, 3, 'March 2026', '2026-03-01', '2026-03-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(4, 1, 1, 4, 'April 2026', '2026-04-01', '2026-04-30', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(5, 1, 1, 5, 'May 2026', '2026-05-01', '2026-05-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(6, 1, 1, 6, 'June 2026', '2026-06-01', '2026-06-30', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(7, 1, 1, 7, 'July 2026', '2026-07-01', '2026-07-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(8, 1, 1, 8, 'August 2026', '2026-08-01', '2026-08-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(9, 1, 1, 9, 'September 2026', '2026-09-01', '2026-09-30', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(10, 1, 1, 10, 'October 2026', '2026-10-01', '2026-10-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(11, 1, 1, 11, 'November 2026', '2026-11-01', '2026-11-30', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(12, 1, 1, 12, 'December 2026', '2026-12-01', '2026-12-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(13, 1, 1, 13, 'Year-End Adjustments 2026', '2026-12-31', '2026-12-31', 'open', NULL, NULL, '2026-10-02 06:15:43', '2026-10-02 06:15:43');

-- --------------------------------------------------------

--
-- Table structure for table `finance_profit_records`
--

CREATE TABLE `finance_profit_records` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `transaction_type` enum('ticket','umrah','hotel','transport','visa','service','other') NOT NULL,
  `transaction_id` bigint(20) UNSIGNED NOT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `revenue_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `cost_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `gross_profit` decimal(20,4) GENERATED ALWAYS AS (`revenue_amount` - `cost_amount`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_profit_records`
--

INSERT INTO `finance_profit_records` (`id`, `company_id`, `branch_id`, `transaction_type`, `transaction_id`, `reference_no`, `revenue_amount`, `cost_amount`, `currency_code`, `exchange_rate`, `journal_entry_id`, `created_by`, `created_at`) VALUES
(1, 1, 1, 'ticket', 1, 'TEST-TKT-001', 1500.0000, 1000.0000, 'AFN', 1.00000000, 1, 1, '2026-10-02 07:14:17');

-- --------------------------------------------------------

--
-- Table structure for table `finance_refunds`
--

CREATE TABLE `finance_refunds` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `refund_no` varchar(100) NOT NULL,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `payment_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `refund_date` datetime NOT NULL DEFAULT current_timestamp(),
  `amount` decimal(20,4) NOT NULL,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `reason` text NOT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `status` enum('draft','approved','posted','cancelled') NOT NULL DEFAULT 'draft',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `finance_service_costs`
--

CREATE TABLE `finance_service_costs` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `service_type` enum('ticket','umrah','hotel','transport','visa','other') NOT NULL,
  `service_id` bigint(20) UNSIGNED NOT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `cost_amount` decimal(20,4) NOT NULL,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_service_costs`
--

INSERT INTO `finance_service_costs` (`id`, `company_id`, `branch_id`, `service_type`, `service_id`, `supplier_id`, `cost_amount`, `currency_code`, `exchange_rate`, `invoice_id`, `journal_entry_id`, `notes`, `created_by`, `created_at`) VALUES
(1, 1, 1, 'ticket', 1, 1, 1000.0000, 'AFN', 1.00000000, 1, 1, 'Automatic ticket cost record. Source type: supplier', 1, '2026-10-02 07:14:17');

-- --------------------------------------------------------

--
-- Table structure for table `finance_supplier_ledger`
--

CREATE TABLE `finance_supplier_ledger` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_id` bigint(20) UNSIGNED NOT NULL,
  `entry_date` datetime NOT NULL DEFAULT current_timestamp(),
  `reference_type` varchar(80) NOT NULL,
  `reference_id` bigint(20) UNSIGNED NOT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `debit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `payment_id` bigint(20) UNSIGNED DEFAULT NULL,
  `description` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_supplier_ledger`
--

INSERT INTO `finance_supplier_ledger` (`id`, `company_id`, `branch_id`, `supplier_id`, `entry_date`, `reference_type`, `reference_id`, `reference_no`, `debit_amount`, `credit_amount`, `currency_code`, `exchange_rate`, `journal_entry_id`, `invoice_id`, `payment_id`, `description`, `created_at`) VALUES
(1, 1, 1, 1, '2026-10-02 07:14:16', 'ticket', 1, 'TEST-TKT-001', 0.0000, 1000.0000, 'AFN', 1.00000000, 1, 1, NULL, 'Ticket supplier payable - TEST-TKT-001', '2026-10-02 07:14:17');

-- --------------------------------------------------------

--
-- Table structure for table `finance_transaction_links`
--

CREATE TABLE `finance_transaction_links` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `transaction_type` enum('ticket','umrah','hotel','transport','visa','invitation','service','expense','other') NOT NULL,
  `transaction_id` bigint(20) UNSIGNED NOT NULL,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `payment_id` bigint(20) UNSIGNED DEFAULT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `finance_transaction_links`
--

INSERT INTO `finance_transaction_links` (`id`, `company_id`, `branch_id`, `transaction_type`, `transaction_id`, `invoice_id`, `payment_id`, `journal_entry_id`, `reference_no`, `notes`, `created_by`, `created_at`) VALUES
(1, 1, 1, 'ticket', 1, 1, NULL, 1, 'TEST-TKT-001', 'Automatic Ticket Accounting transaction link.', 1, '2026-10-02 07:14:17'),
(2, 1, 1, 'other', 1, 1, 1, 3, 'PAY-000001', 'Payment accounting link', 1, '2026-10-02 07:16:59');

-- --------------------------------------------------------

--
-- Table structure for table `foreign_visitors`
--

CREATE TABLE `foreign_visitors` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `visitor_no` varchar(80) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `full_name_local` varchar(255) DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `nationality_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `passport_no` varchar(100) NOT NULL,
  `passport_issue_date` date DEFAULT NULL,
  `passport_expiry_date` date DEFAULT NULL,
  `passport_issue_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `occupation` varchar(190) DEFAULT NULL,
  `employer` varchar(190) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `emergency_contact_name` varchar(190) DEFAULT NULL,
  `emergency_contact_phone` varchar(50) DEFAULT NULL,
  `purpose` enum('tourism','business','visit','work','study','transit','medical','umrah','other') NOT NULL DEFAULT 'tourism',
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `foreign_visitor_documents`
--

CREATE TABLE `foreign_visitor_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `visitor_id` bigint(20) UNSIGNED NOT NULL,
  `document_type` enum('passport','national_id','visa','photo','invitation','travel_permission','insurance','ticket','hotel','other') NOT NULL,
  `document_no` varchar(150) DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `original_file_name` varchar(255) DEFAULT NULL,
  `mime_type` varchar(100) DEFAULT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `verification_status` enum('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `hotels`
--

CREATE TABLE `hotels` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `hotel_code` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `name_local` varchar(190) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `website` varchar(255) DEFAULT NULL,
  `star_rating` decimal(3,1) DEFAULT NULL,
  `distance_category` enum('near','medium','far') DEFAULT NULL,
  `distance_meters` int(10) UNSIGNED DEFAULT NULL,
  `latitude` decimal(10,7) DEFAULT NULL,
  `longitude` decimal(10,7) DEFAULT NULL,
  `description` text DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `hotel_bookings`
--

CREATE TABLE `hotel_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `hotel_id` bigint(20) UNSIGNED NOT NULL,
  `room_type_id` bigint(20) UNSIGNED DEFAULT NULL,
  `reservation_no` varchar(100) NOT NULL,
  `check_in` date NOT NULL,
  `check_out` date NOT NULL,
  `rooms` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `adults` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `children` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `supplier_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) GENERATED ALWAYS AS (greatest(`selling_price` - `paid_amount`,0)) STORED,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `supplier_cost`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `confirmation_no` varchar(150) DEFAULT NULL,
  `status` enum('draft','reserved','confirmed','checked_in','checked_out','cancelled','no_show') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `hotel_room_types`
--

CREATE TABLE `hotel_room_types` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `hotel_id` bigint(20) UNSIGNED NOT NULL,
  `room_code` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `name_local` varchar(190) DEFAULT NULL,
  `bed_type` varchar(100) DEFAULT NULL,
  `max_adults` int(10) UNSIGNED NOT NULL DEFAULT 2,
  `max_children` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `rooms_available` int(10) UNSIGNED NOT NULL DEFAULT 0,
  `purchase_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `description` text DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `interpreters`
--

CREATE TABLE `interpreters` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `interpreter_no` varchar(80) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `nationality_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `phone` varchar(50) NOT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `languages` text DEFAULT NULL,
  `experience_years` decimal(5,2) DEFAULT NULL,
  `specialization` varchar(255) DEFAULT NULL,
  `commission_rate` decimal(10,4) NOT NULL DEFAULT 0.0000,
  `commission_basis` enum('service_amount','profit','fixed_per_service','mixed') NOT NULL DEFAULT 'service_amount',
  `status` enum('pending','active','suspended','inactive','expired') NOT NULL DEFAULT 'pending',
  `approved_at` datetime DEFAULT NULL,
  `approved_by` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `interpreter_assignments`
--

CREATE TABLE `interpreter_assignments` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `interpreter_id` bigint(20) UNSIGNED NOT NULL,
  `foreign_visitor_id` bigint(20) UNSIGNED NOT NULL,
  `invitation_id` bigint(20) UNSIGNED DEFAULT NULL,
  `assignment_no` varchar(100) NOT NULL,
  `service_reference_no` varchar(150) DEFAULT NULL,
  `start_date` date DEFAULT NULL,
  `end_date` date DEFAULT NULL,
  `commission_rate` decimal(10,4) NOT NULL DEFAULT 0.0000,
  `commission_basis` enum('service_amount','profit','fixed_per_service','mixed') NOT NULL DEFAULT 'service_amount',
  `commission_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `status` enum('pending','assigned','in_progress','completed','cancelled') NOT NULL DEFAULT 'pending',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `interpreter_commissions`
--

CREATE TABLE `interpreter_commissions` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `interpreter_id` bigint(20) UNSIGNED NOT NULL,
  `service_type` varchar(100) NOT NULL,
  `service_reference_id` bigint(20) UNSIGNED DEFAULT NULL,
  `service_reference_no` varchar(150) DEFAULT NULL,
  `service_date` date NOT NULL,
  `base_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `commission_rate` decimal(10,4) NOT NULL DEFAULT 0.0000,
  `commission_amount` decimal(20,4) GENERATED ALWAYS AS (`base_amount` * `commission_rate` / 100) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `payment_status` enum('unpaid','partially_paid','paid','cancelled') NOT NULL DEFAULT 'unpaid',
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `interpreter_documents`
--

CREATE TABLE `interpreter_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `interpreter_id` bigint(20) UNSIGNED NOT NULL,
  `document_type` enum('tazkira','passport','guarantee_letter','photo','certificate','contract','other') NOT NULL,
  `document_no` varchar(150) DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `original_file_name` varchar(255) DEFAULT NULL,
  `mime_type` varchar(100) DEFAULT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `verification_status` enum('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `interpreter_id_cards`
--

CREATE TABLE `interpreter_id_cards` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `interpreter_id` bigint(20) UNSIGNED NOT NULL,
  `card_no` varchar(100) NOT NULL,
  `issue_date` date NOT NULL,
  `expiry_date` date DEFAULT NULL,
  `photo_path` varchar(500) DEFAULT NULL,
  `qr_code` varchar(255) DEFAULT NULL,
  `verification_token` varchar(255) DEFAULT NULL,
  `card_status` enum('pending','active','expired','suspended','cancelled') NOT NULL DEFAULT 'pending',
  `issued_by` bigint(20) UNSIGNED DEFAULT NULL,
  `issued_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitations`
--

CREATE TABLE `invitations` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_no` varchar(80) NOT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `foreign_visitor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_type` varchar(80) NOT NULL DEFAULT 'general',
  `purpose` varchar(255) DEFAULT NULL,
  `destination` varchar(255) DEFAULT NULL,
  `travel_route` text DEFAULT NULL,
  `travel_start_date` date DEFAULT NULL,
  `travel_end_date` date DEFAULT NULL,
  `number_of_visitors` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `issuing_authority` varchar(255) DEFAULT NULL,
  `approval_reference_no` varchar(150) DEFAULT NULL,
  `approved_at` datetime DEFAULT NULL,
  `approved_by` bigint(20) UNSIGNED DEFAULT NULL,
  `permit_no` varchar(150) DEFAULT NULL,
  `permit_issue_date` date DEFAULT NULL,
  `permit_expiry_date` date DEFAULT NULL,
  `status` enum('draft','pending','approved','issued','completed','cancelled','rejected') NOT NULL DEFAULT 'draft',
  `invitation_date` date NOT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitation_documents`
--

CREATE TABLE `invitation_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `invitation_id` bigint(20) UNSIGNED NOT NULL,
  `document_type` enum('invitation','afghan_company_letter','afghan_tour_letter','afghan_permit','travel_permission','foreign_passport','foreign_visitor_id','visa','hotel_document','transport_document','insurance','photo','other') NOT NULL,
  `document_no` varchar(150) DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `original_name` varchar(255) NOT NULL,
  `mime_type` varchar(150) NOT NULL,
  `file_size` bigint(20) UNSIGNED NOT NULL DEFAULT 0,
  `verification_status` enum('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `financial_status` enum('not_applicable','pending','recorded','settled','cancelled') NOT NULL DEFAULT 'not_applicable',
  `financial_reference_no` varchar(150) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `uploaded_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitation_document_financials`
--

CREATE TABLE `invitation_document_financials` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `document_id` bigint(20) UNSIGNED NOT NULL,
  `invitation_id` bigint(20) UNSIGNED NOT NULL,
  `currency_code` char(3) NOT NULL,
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `cost_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `discount_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `total_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `due_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `profit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `financial_status` enum('draft','pending','approved','posted','partially_paid','paid','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `due_date` date DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitation_financials`
--

CREATE TABLE `invitation_financials` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `invitation_id` bigint(20) UNSIGNED NOT NULL,
  `currency_code` char(3) NOT NULL,
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `cost_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `discount_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `total_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `due_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `profit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_cost_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_selling_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_discount_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_total_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_due_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `base_profit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `invoice_id` bigint(20) UNSIGNED DEFAULT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `financial_status` enum('draft','pending','approved','posted','partially_paid','paid','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `due_date` date DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitation_hotel_bookings`
--

CREATE TABLE `invitation_hotel_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_id` bigint(20) UNSIGNED NOT NULL,
  `hotel_booking_id` bigint(20) UNSIGNED NOT NULL,
  `relationship_type` enum('accommodation','primary_hotel','supporting_hotel','other') NOT NULL DEFAULT 'accommodation',
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitation_transport_bookings`
--

CREATE TABLE `invitation_transport_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_id` bigint(20) UNSIGNED NOT NULL,
  `transport_booking_id` bigint(20) UNSIGNED NOT NULL,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invitation_visas`
--

CREATE TABLE `invitation_visas` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_id` bigint(20) UNSIGNED NOT NULL,
  `visa_id` bigint(20) UNSIGNED NOT NULL,
  `relationship_type` enum('application','approved_visa','issued_visa','supporting_visa','other') NOT NULL DEFAULT 'application',
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `invoices`
--

CREATE TABLE `invoices` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invoice_no` varchar(100) NOT NULL,
  `invoice_date` datetime NOT NULL DEFAULT current_timestamp(),
  `due_date` date DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_id` bigint(20) UNSIGNED DEFAULT NULL,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `subtotal` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `discount_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `total_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `balance_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invoice_type` enum('sale','ticket','umrah','hotel','transport','visa','service','foreign_visitor','invitation','other') NOT NULL DEFAULT 'sale',
  `status` enum('draft','issued','partially_paid','paid','overdue','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `invoices`
--

INSERT INTO `invoices` (`id`, `company_id`, `branch_id`, `invoice_no`, `invoice_date`, `due_date`, `customer_id`, `debtor_id`, `agency_id`, `invitation_id`, `currency_code`, `exchange_rate`, `subtotal`, `discount_amount`, `tax_amount`, `total_amount`, `paid_amount`, `balance_amount`, `journal_entry_id`, `invoice_type`, `status`, `notes`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'INV-000003', '2026-10-02 07:14:16', NULL, 1, NULL, NULL, NULL, 'AFN', 1.00000000, 1500.0000, 0.0000, 0.0000, 1500.0000, 1500.0000, 0.0000, 1, 'ticket', 'paid', 'Auto-generated from ticket TEST-TKT-001', 1, 1, '2026-10-02 07:14:17', '2026-10-02 07:16:59', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `invoice_items`
--

CREATE TABLE `invoice_items` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `invoice_id` bigint(20) UNSIGNED NOT NULL,
  `line_no` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `service_id` bigint(20) UNSIGNED DEFAULT NULL,
  `description` varchar(500) NOT NULL,
  `quantity` decimal(20,4) NOT NULL DEFAULT 1.0000,
  `unit_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `discount_id` bigint(20) UNSIGNED DEFAULT NULL,
  `discount_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `tax_id` bigint(20) UNSIGNED DEFAULT NULL,
  `tax_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `line_total` decimal(20,4) GENERATED ALWAYS AS (greatest(`quantity` * `unit_price` - `discount_amount` + `tax_amount`,0)) STORED,
  `ticket_booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `hotel_booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `transport_booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `visa_id` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `invoice_items`
--

INSERT INTO `invoice_items` (`id`, `company_id`, `invoice_id`, `line_no`, `service_id`, `description`, `quantity`, `unit_price`, `discount_id`, `discount_amount`, `tax_id`, `tax_amount`, `ticket_booking_id`, `umrah_booking_id`, `hotel_booking_id`, `transport_booking_id`, `visa_id`, `created_at`) VALUES
(1, 1, 1, 1, NULL, 'Air Ticket TEST-TKT-001 | PNR: TESTPNR001', 1.0000, 1500.0000, NULL, 0.0000, NULL, 0.0000, 1, NULL, NULL, NULL, NULL, '2026-10-02 07:14:17');

-- --------------------------------------------------------

--
-- Table structure for table `journal_entries`
--

CREATE TABLE `journal_entries` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `fiscal_year_id` bigint(20) UNSIGNED DEFAULT NULL,
  `period_id` bigint(20) UNSIGNED DEFAULT NULL,
  `entry_no` varchar(100) NOT NULL,
  `entry_date` datetime NOT NULL DEFAULT current_timestamp(),
  `reference_type` varchar(80) DEFAULT NULL,
  `reference_id` bigint(20) UNSIGNED DEFAULT NULL,
  `reference_no` varchar(150) DEFAULT NULL,
  `description` text NOT NULL,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `total_debit` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `total_credit` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `status` enum('draft','posted','reversed','cancelled') NOT NULL DEFAULT 'draft',
  `reversal_of_id` bigint(20) UNSIGNED DEFAULT NULL,
  `posted_at` datetime DEFAULT NULL,
  `posted_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `journal_entries`
--

INSERT INTO `journal_entries` (`id`, `company_id`, `branch_id`, `fiscal_year_id`, `period_id`, `entry_no`, `entry_date`, `reference_type`, `reference_id`, `reference_no`, `description`, `currency_code`, `exchange_rate`, `total_debit`, `total_credit`, `status`, `reversal_of_id`, `posted_at`, `posted_by`, `created_by`, `updated_by`, `created_at`, `updated_at`) VALUES
(1, 1, 1, 1, 10, 'JE-000001', '2026-10-02 07:14:16', 'ticket', 1, 'TEST-TKT-001', 'Ticket accounting posting - TEST-TKT-001', 'AFN', 1.00000000, 2500.0000, 2500.0000, 'posted', NULL, '2026-10-02 07:14:17', 1, 1, 1, '2026-10-02 07:14:17', '2026-10-02 07:14:17'),
(3, 1, 1, 1, 10, 'JE-000002', '2026-10-02 07:14:18', 'payment', 1, 'PAY-000001', 'Payment PAY-000001', 'AFN', 1.00000000, 1500.0000, 1500.0000, 'posted', NULL, '2026-10-02 07:16:59', 1, 1, 1, '2026-10-02 07:16:59', '2026-10-02 07:16:59');

-- --------------------------------------------------------

--
-- Table structure for table `journal_lines`
--

CREATE TABLE `journal_lines` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `journal_entry_id` bigint(20) UNSIGNED NOT NULL,
  `chart_account_id` bigint(20) UNSIGNED NOT NULL,
  `line_no` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `description` varchar(500) DEFAULT NULL,
  `debit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `finance_account_id` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `journal_lines`
--

INSERT INTO `journal_lines` (`id`, `company_id`, `journal_entry_id`, `chart_account_id`, `line_no`, `description`, `debit_amount`, `credit_amount`, `currency_code`, `exchange_rate`, `customer_id`, `debtor_id`, `supplier_id`, `agency_id`, `finance_account_id`, `created_at`) VALUES
(1, 1, 1, 79, 1, 'Ticket receivable - TEST-TKT-001', 1500.0000, 0.0000, 'AFN', 1.00000000, 1, NULL, NULL, NULL, NULL, '2026-10-02 07:14:17'),
(2, 1, 1, 15, 2, 'Ticket revenue - TEST-TKT-001', 0.0000, 1500.0000, 'AFN', 1.00000000, NULL, NULL, NULL, NULL, NULL, '2026-10-02 07:14:17'),
(3, 1, 1, 23, 3, 'Ticket cost - TEST-TKT-001', 1000.0000, 0.0000, 'AFN', 1.00000000, NULL, NULL, 1, NULL, NULL, '2026-10-02 07:14:17'),
(4, 1, 1, 80, 4, 'Ticket source payable - TEST-TKT-001', 0.0000, 1000.0000, 'AFN', 1.00000000, NULL, NULL, 1, NULL, NULL, '2026-10-02 07:14:17'),
(7, 1, 3, 2, 1, 'Receipt PAY-000001', 1500.0000, 0.0000, 'AFN', 1.00000000, NULL, NULL, NULL, NULL, 1, '2026-10-02 07:16:59'),
(8, 1, 3, 79, 2, 'Receivable settlement PAY-000001', 0.0000, 1500.0000, 'AFN', 1.00000000, 1, NULL, NULL, NULL, NULL, '2026-10-02 07:16:59');

-- --------------------------------------------------------

--
-- Table structure for table `languages`
--

CREATE TABLE `languages` (
  `code` varchar(10) NOT NULL,
  `name` varchar(100) NOT NULL,
  `direction` enum('ltr','rtl') NOT NULL DEFAULT 'ltr',
  `status` enum('active','inactive') NOT NULL DEFAULT 'active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `languages`
--

INSERT INTO `languages` (`code`, `name`, `direction`, `status`) VALUES
('en', 'English', 'ltr', 'active'),
('fa', 'Dari', 'rtl', 'active'),
('ps', 'Pashto', 'rtl', 'active');

-- --------------------------------------------------------

--
-- Table structure for table `login_attempts`
--

CREATE TABLE `login_attempts` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED DEFAULT NULL,
  `username` varchar(190) DEFAULT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL,
  `attempted_at` datetime NOT NULL DEFAULT current_timestamp(),
  `success` tinyint(1) NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `login_history`
--

CREATE TABLE `login_history` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `login_at` datetime NOT NULL DEFAULT current_timestamp(),
  `logout_at` datetime DEFAULT NULL,
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` varchar(500) DEFAULT NULL,
  `session_id_hash` varchar(255) DEFAULT NULL,
  `status` enum('success','logout','forced_logout','expired') NOT NULL DEFAULT 'success'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `number_sequences`
--

CREATE TABLE `number_sequences` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `document_type` varchar(80) NOT NULL,
  `prefix` varchar(30) NOT NULL DEFAULT '',
  `current_number` bigint(20) UNSIGNED NOT NULL DEFAULT 0,
  `padding` tinyint(3) UNSIGNED NOT NULL DEFAULT 6,
  `reset_type` enum('never','yearly','monthly') NOT NULL DEFAULT 'yearly',
  `last_reset_key` varchar(20) DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `number_sequences`
--

INSERT INTO `number_sequences` (`id`, `company_id`, `branch_id`, `document_type`, `prefix`, `current_number`, `padding`, `reset_type`, `last_reset_key`, `status`, `created_at`, `updated_at`) VALUES
(1, 1, 1, 'ticket', 'TKT-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(2, 1, 1, 'invoice', 'INV-', 3, 6, 'yearly', '2026', 'active', '2026-10-02 06:15:43', '2026-10-02 07:14:17'),
(3, 1, 1, 'payment', 'PAY-', 1, 6, 'yearly', '2026', 'active', '2026-10-02 06:15:43', '2026-10-02 07:14:18'),
(4, 1, 1, 'booking', 'BKG-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(5, 1, 1, 'umrah_booking', 'UMB-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(6, 1, 1, 'hotel_booking', 'HTL-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(7, 1, 1, 'transport_booking', 'TRN-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(8, 1, 1, 'visa', 'VISA-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(9, 1, 1, 'expense', 'EXP-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(10, 1, 1, 'journal_entry', 'JE-', 2, 6, 'yearly', '2026', 'active', '2026-10-02 06:15:43', '2026-10-02 07:16:59'),
(11, 1, 1, 'salary_payment', 'SAL-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(12, 1, 1, 'refund', 'REF-', 0, 6, 'yearly', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(13, 1, 1, 'customer', 'CUS-', 0, 6, 'never', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(14, 1, 1, 'debtor', 'DEB-', 0, 6, 'never', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(15, 1, 1, 'supplier', 'SUP-', 0, 6, 'never', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(16, 1, 1, 'agency', 'AGN-', 0, 6, 'never', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43'),
(17, 1, 1, 'employee', 'EMP-', 0, 6, 'never', NULL, 'active', '2026-10-02 06:15:43', '2026-10-02 06:15:43');

-- --------------------------------------------------------

--
-- Table structure for table `passports`
--

CREATE TABLE `passports` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `customer_id` bigint(20) UNSIGNED NOT NULL,
  `passport_no` varchar(100) NOT NULL,
  `passport_type` varchar(50) DEFAULT NULL,
  `nationality_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `issue_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `place_of_birth` varchar(190) DEFAULT NULL,
  `first_name` varchar(100) DEFAULT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `file_path` varchar(500) DEFAULT NULL,
  `status` enum('active','expired','cancelled') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `password_reset_tokens`
--

CREATE TABLE `password_reset_tokens` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `token_hash` varchar(255) NOT NULL,
  `expires_at` datetime NOT NULL,
  `used_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `payments`
--

CREATE TABLE `payments` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `payment_no` varchar(100) NOT NULL,
  `payment_type` enum('receipt','payment','refund') NOT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `finance_account_id` bigint(20) UNSIGNED NOT NULL,
  `payment_date` datetime NOT NULL DEFAULT current_timestamp(),
  `amount` decimal(20,4) NOT NULL,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `payment_method` enum('cash','bank','mobile_wallet','card','transfer','other') NOT NULL DEFAULT 'cash',
  `reference_no` varchar(150) DEFAULT NULL,
  `journal_entry_id` bigint(20) UNSIGNED DEFAULT NULL,
  `status` enum('draft','posted','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `payments`
--

INSERT INTO `payments` (`id`, `company_id`, `branch_id`, `payment_no`, `payment_type`, `customer_id`, `debtor_id`, `supplier_id`, `agency_id`, `finance_account_id`, `payment_date`, `amount`, `currency_code`, `exchange_rate`, `payment_method`, `reference_no`, `journal_entry_id`, `status`, `notes`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'PAY-000001', 'receipt', 1, NULL, NULL, NULL, 1, '2026-10-02 07:14:18', 1500.0000, 'AFN', 1.00000000, 'cash', 'ERP-TEST-PAYMENT', 3, 'posted', 'ERP End-to-End Payment Test', 1, 1, '2026-10-02 07:14:18', '2026-10-02 07:16:59', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `payment_allocations`
--

CREATE TABLE `payment_allocations` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `payment_id` bigint(20) UNSIGNED NOT NULL,
  `invoice_id` bigint(20) UNSIGNED NOT NULL,
  `allocated_amount` decimal(20,4) NOT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `payment_allocations`
--

INSERT INTO `payment_allocations` (`id`, `company_id`, `payment_id`, `invoice_id`, `allocated_amount`, `created_by`, `created_at`) VALUES
(1, 1, 1, 1, 1500.0000, 1, '2026-10-02 07:16:59');

-- --------------------------------------------------------

--
-- Table structure for table `permissions`
--

CREATE TABLE `permissions` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `permission_key` varchar(190) NOT NULL,
  `name` varchar(190) NOT NULL,
  `module` varchar(100) DEFAULT NULL,
  `description` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `plans`
--

CREATE TABLE `plans` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(100) NOT NULL,
  `description` text DEFAULT NULL,
  `monthly_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `annual_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `positions`
--

CREATE TABLE `positions` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `department_id` bigint(20) UNSIGNED DEFAULT NULL,
  `title` varchar(150) NOT NULL,
  `code` varchar(50) DEFAULT NULL,
  `description` text DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `roles`
--

CREATE TABLE `roles` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `name` varchar(100) NOT NULL,
  `description` text DEFAULT NULL,
  `is_system` tinyint(1) NOT NULL DEFAULT 0,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `role_permissions`
--

CREATE TABLE `role_permissions` (
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `role_id` bigint(20) UNSIGNED NOT NULL,
  `permission_id` bigint(20) UNSIGNED NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `services`
--

CREATE TABLE `services` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `category_id` bigint(20) UNSIGNED DEFAULT NULL,
  `code` varchar(50) NOT NULL,
  `name` varchar(190) NOT NULL,
  `description` text DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `service_categories`
--

CREATE TABLE `service_categories` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(50) NOT NULL,
  `name` varchar(190) NOT NULL,
  `description` text DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `service_prices`
--

CREATE TABLE `service_prices` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `service_id` bigint(20) UNSIGNED NOT NULL,
  `currency_code` char(3) NOT NULL,
  `cost_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `effective_from` date DEFAULT NULL,
  `effective_to` date DEFAULT NULL,
  `is_default` tinyint(1) NOT NULL DEFAULT 0,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `suppliers`
--

CREATE TABLE `suppliers` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_no` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `legal_name` varchar(190) DEFAULT NULL,
  `contact_person` varchar(190) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `phone_secondary` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `website` varchar(255) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `tax_no` varchar(100) DEFAULT NULL,
  `registration_no` varchar(100) DEFAULT NULL,
  `credit_limit` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `suppliers`
--

INSERT INTO `suppliers` (`id`, `company_id`, `branch_id`, `supplier_no`, `name`, `legal_name`, `contact_person`, `phone`, `phone_secondary`, `whatsapp`, `email`, `website`, `country_id`, `city_id`, `address`, `tax_no`, `registration_no`, `supplier_type`, `credit_limit`, `notes`, `status`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'TEST-SUP-001', 'ERP Test Ticket Supplier', NULL, 'Test Contact', '0700000001', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'airline', 1000000.0000, NULL, 'active', 1, 1, '2026-10-02 07:14:15', '2026-10-02 07:14:15', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `system_backups`
--

CREATE TABLE `system_backups` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED DEFAULT NULL,
  `backup_no` varchar(100) NOT NULL,
  `backup_type` enum('full','company','database','files','manual','scheduled') NOT NULL DEFAULT 'manual',
  `file_name` varchar(255) NOT NULL,
  `file_path` varchar(500) NOT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `checksum` varchar(128) DEFAULT NULL,
  `started_at` datetime NOT NULL DEFAULT current_timestamp(),
  `completed_at` datetime DEFAULT NULL,
  `status` enum('pending','running','completed','failed','deleted') NOT NULL DEFAULT 'pending',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `system_backup_history`
--

CREATE TABLE `system_backup_history` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED DEFAULT NULL,
  `backup_type` enum('full','structure','data','company','manual','scheduled') NOT NULL DEFAULT 'full',
  `file_name` varchar(255) NOT NULL,
  `file_path` varchar(500) DEFAULT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `checksum_sha256` char(64) DEFAULT NULL,
  `started_at` datetime NOT NULL DEFAULT current_timestamp(),
  `completed_at` datetime DEFAULT NULL,
  `status` enum('started','completed','failed','verified') NOT NULL DEFAULT 'started',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `taxes`
--

CREATE TABLE `taxes` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `code` varchar(50) NOT NULL,
  `name` varchar(190) NOT NULL,
  `rate` decimal(10,4) NOT NULL DEFAULT 0.0000,
  `tax_type` enum('percentage','fixed') NOT NULL DEFAULT 'percentage',
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ticket_bookings`
--

CREATE TABLE `ticket_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `passenger_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `ticket_no` varchar(100) NOT NULL,
  `reservation_date` datetime NOT NULL DEFAULT current_timestamp(),
  `departure_date` datetime DEFAULT NULL,
  `ticket_type` enum('normal','general','umrah','group') NOT NULL DEFAULT 'normal',
  `source_id` bigint(20) UNSIGNED DEFAULT NULL,
  `airline_id` bigint(20) UNSIGNED DEFAULT NULL,
  `pnr` varchar(100) DEFAULT NULL,
  `cost_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `cost_price`) STORED,
  `credit_due_date` date DEFAULT NULL,
  `status` enum('draft','reserved','confirmed','issued','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `passenger_phone` varchar(50) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `ticket_bookings`
--

INSERT INTO `ticket_bookings` (`id`, `company_id`, `branch_id`, `booking_id`, `passenger_id`, `customer_id`, `debtor_id`, `ticket_no`, `reservation_date`, `departure_date`, `ticket_type`, `source_id`, `airline_id`, `pnr`, `cost_price`, `selling_price`, `currency_code`, `exchange_rate`, `paid_amount`, `credit_amount`, `credit_due_date`, `status`, `passenger_phone`, `notes`, `created_by`, `updated_by`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 1, 1, 1, NULL, 'TEST-TKT-001', '2026-10-02 07:14:16', '2026-10-12 07:14:16', 'normal', 1, NULL, 'TESTPNR001', 1000.0000, 1500.0000, 'AFN', 1.00000000, 0.0000, 1500.0000, '2026-11-01', 'issued', '0700000000', 'ERP End-to-End Ticket Test', 1, 1, '2026-10-02 07:14:16', '2026-10-02 07:14:16', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `ticket_documents`
--

CREATE TABLE `ticket_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `document_type` enum('original_ticket','supplier_ticket','system_ticket','invoice','customer_copy','other') NOT NULL DEFAULT 'original_ticket',
  `document_no` varchar(150) DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `original_name` varchar(255) DEFAULT NULL,
  `mime_type` varchar(100) DEFAULT NULL,
  `file_size` bigint(20) UNSIGNED DEFAULT NULL,
  `uploaded_by` bigint(20) UNSIGNED DEFAULT NULL,
  `is_customer_visible` tinyint(1) NOT NULL DEFAULT 0,
  `verification_status` enum('pending','verified','rejected') NOT NULL DEFAULT 'pending',
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ticket_refunds`
--

CREATE TABLE `ticket_refunds` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `refund_no` varchar(80) NOT NULL,
  `refund_date` datetime NOT NULL DEFAULT current_timestamp(),
  `refund_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `refund_reason` varchar(500) DEFAULT NULL,
  `supplier_refund_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `customer_refund_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `refund_fee` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `status` enum('draft','approved','processed','cancelled') NOT NULL DEFAULT 'draft',
  `payment_id` bigint(20) UNSIGNED DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ticket_segments`
--

CREATE TABLE `ticket_segments` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_id` bigint(20) UNSIGNED NOT NULL,
  `segment_no` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `from_airport_id` bigint(20) UNSIGNED NOT NULL,
  `to_airport_id` bigint(20) UNSIGNED NOT NULL,
  `departure_datetime` datetime DEFAULT NULL,
  `arrival_datetime` datetime DEFAULT NULL,
  `flight_number` varchar(50) DEFAULT NULL,
  `airline_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_class` varchar(20) DEFAULT NULL,
  `cabin_class` varchar(50) DEFAULT NULL,
  `baggage_allowance` varchar(100) DEFAULT NULL,
  `duration_minutes` int(10) UNSIGNED DEFAULT NULL,
  `status` enum('scheduled','flown','cancelled','changed') NOT NULL DEFAULT 'scheduled',
  `notes` text DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `ticket_sources`
--

CREATE TABLE `ticket_sources` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `source_type` enum('supplier','agency','airline','system','direct','other') NOT NULL DEFAULT 'supplier',
  `source_name` varchar(190) NOT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `airline_id` bigint(20) UNSIGNED DEFAULT NULL,
  `external_system` varchar(190) DEFAULT NULL,
  `external_reference` varchar(190) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive') NOT NULL DEFAULT 'active',
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `ticket_sources`
--

INSERT INTO `ticket_sources` (`id`, `company_id`, `source_type`, `source_name`, `supplier_id`, `agency_id`, `airline_id`, `external_system`, `external_reference`, `notes`, `status`, `created_at`, `updated_at`) VALUES
(1, 1, 'supplier', 'ERP TEST SOURCE', 1, NULL, NULL, NULL, NULL, NULL, 'active', '2026-10-02 07:14:15', '2026-10-02 07:14:15');

-- --------------------------------------------------------

--
-- Table structure for table `translations`
--

CREATE TABLE `translations` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `language_code` varchar(10) NOT NULL,
  `translation_key` varchar(190) NOT NULL,
  `translation_value` text NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `transport_bookings`
--

CREATE TABLE `transport_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `vehicle_id` bigint(20) UNSIGNED NOT NULL,
  `driver_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `transport_no` varchar(100) NOT NULL,
  `service_date` date NOT NULL,
  `pickup_time` time DEFAULT NULL,
  `pickup_location` varchar(255) NOT NULL,
  `dropoff_location` varchar(255) NOT NULL,
  `passenger_count` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `supplier_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) GENERATED ALWAYS AS (greatest(`selling_price` - `paid_amount`,0)) STORED,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `supplier_cost`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `status` enum('draft','reserved','confirmed','in_progress','completed','cancelled','no_show') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_bookings`
--

CREATE TABLE `umrah_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_id` bigint(20) UNSIGNED NOT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `package_id` bigint(20) UNSIGNED NOT NULL,
  `umrah_no` varchar(100) NOT NULL,
  `group_name` varchar(190) DEFAULT NULL,
  `group_no` varchar(100) DEFAULT NULL,
  `source_type` enum('own_system','nusuk','supplier','agency','other') NOT NULL DEFAULT 'own_system',
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `departure_date` date DEFAULT NULL,
  `return_date` date DEFAULT NULL,
  `purchase_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) GENERATED ALWAYS AS (greatest(`selling_price` - `paid_amount`,0)) STORED,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `purchase_cost`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `status` enum('draft','reserved','confirmed','processing','visa_pending','visa_issued','completed','cancelled','refunded') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_documents`
--

CREATE TABLE `umrah_documents` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED NOT NULL,
  `umrah_passenger_id` bigint(20) UNSIGNED DEFAULT NULL,
  `document_type` enum('passport','national_id','photo','guarantee_letter','visa','flight_ticket','hotel_confirmation','insurance','vaccination','medical','contract','other') NOT NULL,
  `document_no` varchar(150) DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `file_path` varchar(500) NOT NULL,
  `original_name` varchar(255) NOT NULL,
  `mime_type` varchar(150) NOT NULL,
  `file_size` bigint(20) UNSIGNED NOT NULL DEFAULT 0,
  `verification_status` enum('pending','verified','rejected','expired') NOT NULL DEFAULT 'pending',
  `verified_by` bigint(20) UNSIGNED DEFAULT NULL,
  `verified_at` datetime DEFAULT NULL,
  `is_required` tinyint(1) NOT NULL DEFAULT 0,
  `is_received` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `uploaded_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_hotel_bookings`
--

CREATE TABLE `umrah_hotel_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED NOT NULL,
  `hotel_booking_id` bigint(20) UNSIGNED NOT NULL,
  `hotel_city` enum('makkah','madinah','other') NOT NULL DEFAULT 'other',
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_packages`
--

CREATE TABLE `umrah_packages` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `package_code` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `name_local` varchar(190) DEFAULT NULL,
  `duration_days` int(10) UNSIGNED NOT NULL,
  `hotel_distance` enum('near','medium','far') DEFAULT NULL,
  `makkah_hotel_id` bigint(20) UNSIGNED DEFAULT NULL,
  `madinah_hotel_id` bigint(20) UNSIGNED DEFAULT NULL,
  `transport_included` tinyint(1) NOT NULL DEFAULT 0,
  `visa_included` tinyint(1) NOT NULL DEFAULT 0,
  `flight_included` tinyint(1) NOT NULL DEFAULT 0,
  `price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `cost_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `description` text DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_passengers`
--

CREATE TABLE `umrah_passengers` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED NOT NULL,
  `passenger_no` varchar(100) NOT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `family_member_id` bigint(20) UNSIGNED DEFAULT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) NOT NULL,
  `father_name` varchar(190) DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `date_of_birth` date DEFAULT NULL,
  `nationality_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `national_id` varchar(100) DEFAULT NULL,
  `passport_no` varchar(100) DEFAULT NULL,
  `passport_issue_date` date DEFAULT NULL,
  `passport_expiry_date` date DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `whatsapp` varchar(50) DEFAULT NULL,
  `email` varchar(190) DEFAULT NULL,
  `relationship` varchar(100) DEFAULT NULL,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `purchase_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) GENERATED ALWAYS AS (greatest(`selling_price` - `paid_amount`,0)) STORED,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `purchase_cost`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `status` enum('draft','pending','documents_pending','ready','completed','cancelled') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_ticket_bookings`
--

CREATE TABLE `umrah_ticket_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED NOT NULL,
  `umrah_passenger_id` bigint(20) UNSIGNED DEFAULT NULL,
  `ticket_booking_id` bigint(20) UNSIGNED NOT NULL,
  `ticket_role` enum('departure','return','round_trip','internal','other') NOT NULL DEFAULT 'round_trip',
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `umrah_transport_bookings`
--

CREATE TABLE `umrah_transport_bookings` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED NOT NULL,
  `transport_booking_id` bigint(20) UNSIGNED NOT NULL,
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `users`
--

CREATE TABLE `users` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `username` varchar(100) NOT NULL,
  `email` varchar(190) DEFAULT NULL,
  `password_hash` varchar(255) NOT NULL,
  `first_name` varchar(100) NOT NULL,
  `middle_name` varchar(100) DEFAULT NULL,
  `last_name` varchar(100) DEFAULT NULL,
  `phone` varchar(50) DEFAULT NULL,
  `language_code` varchar(10) NOT NULL DEFAULT 'ps',
  `status` enum('active','inactive','suspended') NOT NULL DEFAULT 'active',
  `email_verified_at` datetime DEFAULT NULL,
  `last_login_at` datetime DEFAULT NULL,
  `remember_token_hash` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `users`
--

INSERT INTO `users` (`id`, `company_id`, `branch_id`, `username`, `email`, `password_hash`, `first_name`, `middle_name`, `last_name`, `phone`, `language_code`, `status`, `email_verified_at`, `last_login_at`, `remember_token_hash`, `created_at`, `updated_at`, `deleted_at`) VALUES
(1, 1, 1, 'admin', 'erp_test_user@local.test', '$2y$12$/QOzhbp6J3e2cbQxxkce1u1TrNp7SI8GcFzwEUuASCNB8cW8SyqI.', 'ERP', NULL, 'Test', '0000000000', 'en', 'active', NULL, '2026-10-04 21:36:35', NULL, '2026-10-02 07:14:14', '2026-10-04 21:36:35', NULL);

-- --------------------------------------------------------

--
-- Table structure for table `user_roles`
--

CREATE TABLE `user_roles` (
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `user_id` bigint(20) UNSIGNED NOT NULL,
  `role_id` bigint(20) UNSIGNED NOT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `vehicles`
--

CREATE TABLE `vehicles` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `vehicle_code` varchar(80) NOT NULL,
  `plate_number` varchar(80) NOT NULL,
  `vehicle_type` enum('bus','minibus','van','car','suv','taxi','truck','other') NOT NULL DEFAULT 'car',
  `make` varchar(100) DEFAULT NULL,
  `model` varchar(100) DEFAULT NULL,
  `model_year` year(4) DEFAULT NULL,
  `color` varchar(50) DEFAULT NULL,
  `seats` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `registration_no` varchar(150) DEFAULT NULL,
  `registration_expiry` date DEFAULT NULL,
  `insurance_no` varchar(150) DEFAULT NULL,
  `insurance_expiry` date DEFAULT NULL,
  `daily_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `daily_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `notes` text DEFAULT NULL,
  `status` enum('available','reserved','in_service','maintenance','inactive') NOT NULL DEFAULT 'available',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `visas`
--

CREATE TABLE `visas` (
  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `visa_no` varchar(100) DEFAULT NULL,
  `application_no` varchar(150) DEFAULT NULL,
  `visa_category` enum('umrah','foreign_country') NOT NULL,
  `visa_type` enum('tourist','visit','business','work','student','transit','medical','family','umrah','other') NOT NULL DEFAULT 'other',
  `foreign_visitor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `umrah_passenger_id` bigint(20) UNSIGNED DEFAULT NULL,
  `source_type` enum('own_system','nusuk','supplier','agency','embassy','other') NOT NULL DEFAULT 'supplier',
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `agency_id` bigint(20) UNSIGNED DEFAULT NULL,
  `issuing_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `destination_country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `issue_date` date DEFAULT NULL,
  `expiry_date` date DEFAULT NULL,
  `entry_date` date DEFAULT NULL,
  `exit_date` date DEFAULT NULL,
  `entries` enum('single','multiple') NOT NULL DEFAULT 'single',
  `duration_days` int(10) UNSIGNED DEFAULT NULL,
  `purchase_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) GENERATED ALWAYS AS (greatest(`selling_price` - `paid_amount`,0)) STORED,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `purchase_cost`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `status` enum('draft','application','submitted','processing','approved','issued','rejected','expired','cancelled') NOT NULL DEFAULT 'draft',
  `visa_file_path` varchar(500) DEFAULT NULL,
  `original_file_name` varchar(255) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_business_accounting_status`
-- (See below for the actual view)
--
CREATE TABLE `vw_business_accounting_status` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`transaction_type` enum('ticket','umrah','hotel','transport','visa','invitation','service','expense','other')
,`transaction_id` bigint(20) unsigned
,`invoice_id` bigint(20) unsigned
,`journal_entry_id` bigint(20) unsigned
,`reference_no` varchar(150)
,`journal_status` enum('draft','posted','reversed','cancelled')
,`invoice_status` enum('draft','issued','partially_paid','paid','overdue','cancelled','refunded')
,`total_amount` decimal(20,4)
,`paid_amount` decimal(20,4)
,`balance_amount` decimal(20,4)
,`revenue_amount` decimal(20,4)
,`cost_amount` decimal(20,4)
,`gross_profit` decimal(20,4)
,`created_at` datetime
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_business_service_profit_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_business_service_profit_summary` (
`company_id` bigint(20) unsigned
,`transaction_type` enum('ticket','umrah','hotel','transport','visa','service','other')
,`services_count` bigint(21)
,`revenue` decimal(42,4)
,`cost` decimal(42,4)
,`profit` decimal(42,4)
,`margin_percent` decimal(48,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_dashboard_agency_payables`
-- (See below for the actual view)
--
CREATE TABLE `vw_dashboard_agency_payables` (
`company_id` bigint(20) unsigned
,`currency_code` char(3)
,`total_credit` decimal(42,4)
,`total_debit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_dashboard_business_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_dashboard_business_summary` (
`company_id` bigint(20) unsigned
,`transaction_type` enum('ticket','umrah','hotel','transport','visa','service','other')
,`transaction_count` bigint(21)
,`revenue` decimal(42,4)
,`cost` decimal(42,4)
,`gross_profit` decimal(42,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_dashboard_customer_receivables`
-- (See below for the actual view)
--
CREATE TABLE `vw_dashboard_customer_receivables` (
`company_id` bigint(20) unsigned
,`currency_code` char(3)
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_dashboard_daily_kpis`
-- (See below for the actual view)
--
CREATE TABLE `vw_dashboard_daily_kpis` (
`company_id` bigint(20) unsigned
,`business_date` date
,`transactions` bigint(21)
,`revenue` decimal(42,4)
,`cost` decimal(42,4)
,`profit` decimal(42,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_dashboard_supplier_payables`
-- (See below for the actual view)
--
CREATE TABLE `vw_dashboard_supplier_payables` (
`company_id` bigint(20) unsigned
,`currency_code` char(3)
,`total_credit` decimal(42,4)
,`total_debit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_employee_attendance_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_employee_attendance_summary` (
`company_id` bigint(20) unsigned
,`employee_id` bigint(20) unsigned
,`attendance_records` bigint(21)
,`present_days` decimal(22,0)
,`absent_days` decimal(22,0)
,`late_days` decimal(22,0)
,`worked_hours` decimal(30,2)
,`overtime_hours` decimal(30,2)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_employee_directory`
-- (See below for the actual view)
--
CREATE TABLE `vw_employee_directory` (
`id` bigint(20) unsigned
,`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`employee_no` varchar(100)
,`first_name` varchar(100)
,`middle_name` varchar(100)
,`last_name` varchar(100)
,`father_name` varchar(150)
,`full_name` varchar(302)
,`gender` enum('male','female','other')
,`date_of_birth` date
,`phone` varchar(50)
,`whatsapp` varchar(50)
,`email` varchar(150)
,`department_name` varchar(150)
,`position_title` varchar(150)
,`employment_type` enum('full_time','part_time','contract','temporary','intern')
,`joining_date` date
,`leaving_date` date
,`basic_salary` decimal(20,4)
,`salary_currency` char(3)
,`status` enum('active','inactive','on_leave','terminated')
,`created_at` datetime
,`updated_at` datetime
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_agency_balance`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_agency_balance` (
`company_id` bigint(20) unsigned
,`agency_id` bigint(20) unsigned
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_agency_statement`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_agency_statement` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`agency_id` bigint(20) unsigned
,`entry_date` datetime
,`reference_type` varchar(80)
,`reference_id` bigint(20) unsigned
,`reference_no` varchar(150)
,`debit_amount` decimal(20,4)
,`credit_amount` decimal(20,4)
,`net_amount` decimal(21,4)
,`currency_code` char(3)
,`invoice_id` bigint(20) unsigned
,`payment_id` bigint(20) unsigned
,`journal_entry_id` bigint(20) unsigned
,`description` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_agency_statement_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_agency_statement_summary` (
`company_id` bigint(20) unsigned
,`agency_id` bigint(20) unsigned
,`currency_code` char(3)
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`net_balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_ap_aging_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_ap_aging_summary` (
`company_id` bigint(20) unsigned
,`total_payable` decimal(65,4)
,`current_amount` decimal(65,4)
,`days_1_30` decimal(65,4)
,`days_31_60` decimal(65,4)
,`days_61_90` decimal(65,4)
,`days_90_plus` decimal(65,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_ar_aging_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_ar_aging_summary` (
`company_id` bigint(20) unsigned
,`current_amount` decimal(42,4)
,`days_1_30` decimal(42,4)
,`days_31_60` decimal(42,4)
,`days_61_90` decimal(42,4)
,`days_90_plus` decimal(42,4)
,`total_receivable` decimal(42,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_balance_sheet`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_balance_sheet` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`account_type` enum('asset','liability','equity','revenue','expense')
,`account_code` varchar(50)
,`account_name` varchar(190)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_cash_bank`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_cash_bank` (
`company_id` bigint(20) unsigned
,`finance_account_id` bigint(20) unsigned
,`account_no` varchar(80)
,`name` varchar(190)
,`account_type` enum('cash','bank','mobile_wallet','card','other')
,`currency_code` char(3)
,`opening_balance` decimal(20,4)
,`movement_amount` decimal(42,4)
,`calculated_balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_customer_balance`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_customer_balance` (
`company_id` bigint(20) unsigned
,`customer_id` bigint(20) unsigned
,`debtor_id` bigint(20) unsigned
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_customer_statement`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_customer_statement` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`customer_id` bigint(20) unsigned
,`debtor_id` bigint(20) unsigned
,`entry_date` datetime
,`reference_type` varchar(80)
,`reference_id` bigint(20) unsigned
,`reference_no` varchar(150)
,`debit_amount` decimal(20,4)
,`credit_amount` decimal(20,4)
,`net_amount` decimal(21,4)
,`currency_code` char(3)
,`invoice_id` bigint(20) unsigned
,`payment_id` bigint(20) unsigned
,`journal_entry_id` bigint(20) unsigned
,`description` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_expenses`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_expenses` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`account_code` varchar(50)
,`account_name` varchar(190)
,`expense_amount` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_general_ledger`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_general_ledger` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`entry_date` datetime
,`entry_no` varchar(100)
,`reference_type` varchar(80)
,`reference_id` bigint(20) unsigned
,`reference_no` varchar(150)
,`account_code` varchar(50)
,`account_name` varchar(190)
,`description` varchar(500)
,`debit_amount` decimal(20,4)
,`credit_amount` decimal(20,4)
,`currency_code` char(3)
,`status` enum('draft','posted','reversed','cancelled')
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_invoice_aging`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_invoice_aging` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`invoice_id` bigint(20) unsigned
,`invoice_no` varchar(100)
,`invoice_date` datetime
,`due_date` date
,`customer_id` bigint(20) unsigned
,`debtor_id` bigint(20) unsigned
,`total_amount` decimal(20,4)
,`paid_amount` decimal(20,4)
,`balance_amount` decimal(20,4)
,`aging_bucket` varchar(11)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_payables_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_payables_summary` (
`company_id` bigint(20) unsigned
,`currency_code` char(3)
,`total_credit` decimal(42,4)
,`total_debit` decimal(42,4)
,`payable_balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_payment_status`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_payment_status` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`payment_id` bigint(20) unsigned
,`payment_no` varchar(100)
,`payment_type` enum('receipt','payment','refund')
,`payment_date` datetime
,`amount` decimal(20,4)
,`currency_code` char(3)
,`status` enum('draft','posted','cancelled','refunded')
,`journal_entry_id` bigint(20) unsigned
,`allocated_amount` decimal(42,4)
,`unallocated_amount` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_profit_loss`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_profit_loss` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`total_revenue` decimal(43,4)
,`total_expenses` decimal(43,4)
,`net_profit` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_receivables_summary`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_receivables_summary` (
`company_id` bigint(20) unsigned
,`currency_code` char(3)
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`receivable_balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_revenue`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_revenue` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`account_code` varchar(50)
,`account_name` varchar(190)
,`revenue_amount` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_service_profit`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_service_profit` (
`company_id` bigint(20) unsigned
,`transaction_type` enum('ticket','umrah','hotel','transport','visa','service','other')
,`transaction_count` bigint(21)
,`revenue` decimal(42,4)
,`cost` decimal(42,4)
,`gross_profit` decimal(42,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_supplier_balance`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_supplier_balance` (
`company_id` bigint(20) unsigned
,`supplier_id` bigint(20) unsigned
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_supplier_statement`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_supplier_statement` (
`company_id` bigint(20) unsigned
,`branch_id` bigint(20) unsigned
,`supplier_id` bigint(20) unsigned
,`entry_date` datetime
,`reference_type` varchar(80)
,`reference_id` bigint(20) unsigned
,`reference_no` varchar(150)
,`debit_amount` decimal(20,4)
,`credit_amount` decimal(20,4)
,`payable_change` decimal(21,4)
,`currency_code` char(3)
,`invoice_id` bigint(20) unsigned
,`payment_id` bigint(20) unsigned
,`journal_entry_id` bigint(20) unsigned
,`description` text
);

-- --------------------------------------------------------

--
-- Stand-in structure for view `vw_finance_trial_balance`
-- (See below for the actual view)
--
CREATE TABLE `vw_finance_trial_balance` (
`company_id` bigint(20) unsigned
,`chart_account_id` bigint(20) unsigned
,`account_code` varchar(50)
,`account_name` varchar(190)
,`account_type` enum('asset','liability','equity','revenue','expense')
,`total_debit` decimal(42,4)
,`total_credit` decimal(42,4)
,`balance` decimal(43,4)
);

-- --------------------------------------------------------

--
--

  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `booking_id` bigint(20) UNSIGNED DEFAULT NULL,
  `customer_id` bigint(20) UNSIGNED DEFAULT NULL,
  `debtor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `foreign_visitor_id` bigint(20) UNSIGNED DEFAULT NULL,
  `invitation_id` bigint(20) UNSIGNED DEFAULT NULL,
  `service_date` date NOT NULL,
  `service_time` time DEFAULT NULL,
  `pickup_location` varchar(255) DEFAULT NULL,
  `dropoff_location` varchar(255) DEFAULT NULL,
  `passenger_count` int(10) UNSIGNED NOT NULL DEFAULT 1,
  `supplier_id` bigint(20) UNSIGNED DEFAULT NULL,
  `purchase_cost` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `selling_price` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `paid_amount` decimal(20,4) NOT NULL DEFAULT 0.0000,
  `credit_amount` decimal(20,4) GENERATED ALWAYS AS (greatest(`selling_price` - `paid_amount`,0)) STORED,
  `profit_amount` decimal(20,4) GENERATED ALWAYS AS (`selling_price` - `purchase_cost`) STORED,
  `currency_code` char(3) NOT NULL DEFAULT 'AFN',
  `exchange_rate` decimal(20,8) NOT NULL DEFAULT 1.00000000,
  `status` enum('draft','reserved','confirmed','in_progress','completed','cancelled','no_show') NOT NULL DEFAULT 'draft',
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
--

  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `site_code` varchar(80) NOT NULL,
  `name` varchar(190) NOT NULL,
  `name_local` varchar(190) DEFAULT NULL,
  `country_id` bigint(20) UNSIGNED DEFAULT NULL,
  `city_id` bigint(20) UNSIGNED DEFAULT NULL,
  `address` text DEFAULT NULL,
  `latitude` decimal(10,7) DEFAULT NULL,
  `longitude` decimal(10,7) DEFAULT NULL,
  `description` text DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `status` enum('active','inactive','blocked') NOT NULL DEFAULT 'active',
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
--

  `id` bigint(20) UNSIGNED NOT NULL,
  `company_id` bigint(20) UNSIGNED NOT NULL,
  `branch_id` bigint(20) UNSIGNED DEFAULT NULL,
  `transport_booking_id` bigint(20) UNSIGNED NOT NULL,
  `relationship_type` enum('pickup','dropoff','round_trip','tour_transport','other') NOT NULL DEFAULT 'tour_transport',
  `is_primary` tinyint(1) NOT NULL DEFAULT 0,
  `notes` text DEFAULT NULL,
  `created_by` bigint(20) UNSIGNED DEFAULT NULL,
  `updated_by` bigint(20) UNSIGNED DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT current_timestamp(),
  `updated_at` datetime NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `deleted_at` datetime DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Structure for view `vw_business_accounting_status`
--
DROP TABLE IF EXISTS `vw_business_accounting_status`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_business_accounting_status`  AS SELECT `ftl`.`company_id` AS `company_id`, `ftl`.`branch_id` AS `branch_id`, `ftl`.`transaction_type` AS `transaction_type`, `ftl`.`transaction_id` AS `transaction_id`, `ftl`.`invoice_id` AS `invoice_id`, `ftl`.`journal_entry_id` AS `journal_entry_id`, `ftl`.`reference_no` AS `reference_no`, `je`.`status` AS `journal_status`, `i`.`status` AS `invoice_status`, `i`.`total_amount` AS `total_amount`, `i`.`paid_amount` AS `paid_amount`, `i`.`balance_amount` AS `balance_amount`, `fpr`.`revenue_amount` AS `revenue_amount`, `fpr`.`cost_amount` AS `cost_amount`, `fpr`.`gross_profit` AS `gross_profit`, `ftl`.`created_at` AS `created_at` FROM (((`finance_transaction_links` `ftl` left join `journal_entries` `je` on(`je`.`company_id` = `ftl`.`company_id` and `je`.`id` = `ftl`.`journal_entry_id`)) left join `invoices` `i` on(`i`.`company_id` = `ftl`.`company_id` and `i`.`id` = `ftl`.`invoice_id`)) left join `finance_profit_records` `fpr` on(`fpr`.`company_id` = `ftl`.`company_id` and `fpr`.`transaction_type` = `ftl`.`transaction_type` and `fpr`.`transaction_id` = `ftl`.`transaction_id`)) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_business_service_profit_summary`
--
DROP TABLE IF EXISTS `vw_business_service_profit_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_business_service_profit_summary`  AS SELECT `finance_profit_records`.`company_id` AS `company_id`, `finance_profit_records`.`transaction_type` AS `transaction_type`, count(0) AS `services_count`, sum(`finance_profit_records`.`revenue_amount`) AS `revenue`, sum(`finance_profit_records`.`cost_amount`) AS `cost`, sum(`finance_profit_records`.`gross_profit`) AS `profit`, CASE WHEN sum(`finance_profit_records`.`revenue_amount`) = 0 THEN 0 ELSE round(sum(`finance_profit_records`.`gross_profit`) / sum(`finance_profit_records`.`revenue_amount`) * 100,2) END AS `margin_percent` FROM `finance_profit_records` GROUP BY `finance_profit_records`.`company_id`, `finance_profit_records`.`transaction_type` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_dashboard_agency_payables`
--
DROP TABLE IF EXISTS `vw_dashboard_agency_payables`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_dashboard_agency_payables`  AS SELECT `finance_agency_ledger`.`company_id` AS `company_id`, `finance_agency_ledger`.`currency_code` AS `currency_code`, sum(`finance_agency_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_agency_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_agency_ledger`.`credit_amount` - `finance_agency_ledger`.`debit_amount`) AS `balance` FROM `finance_agency_ledger` GROUP BY `finance_agency_ledger`.`company_id`, `finance_agency_ledger`.`currency_code` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_dashboard_business_summary`
--
DROP TABLE IF EXISTS `vw_dashboard_business_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_dashboard_business_summary`  AS SELECT `finance_profit_records`.`company_id` AS `company_id`, `finance_profit_records`.`transaction_type` AS `transaction_type`, count(0) AS `transaction_count`, coalesce(sum(`finance_profit_records`.`revenue_amount`),0) AS `revenue`, coalesce(sum(`finance_profit_records`.`cost_amount`),0) AS `cost`, coalesce(sum(`finance_profit_records`.`gross_profit`),0) AS `gross_profit` FROM `finance_profit_records` GROUP BY `finance_profit_records`.`company_id`, `finance_profit_records`.`transaction_type` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_dashboard_customer_receivables`
--
DROP TABLE IF EXISTS `vw_dashboard_customer_receivables`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_dashboard_customer_receivables`  AS SELECT `finance_customer_ledger`.`company_id` AS `company_id`, `finance_customer_ledger`.`currency_code` AS `currency_code`, sum(`finance_customer_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_customer_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_customer_ledger`.`debit_amount` - `finance_customer_ledger`.`credit_amount`) AS `balance` FROM `finance_customer_ledger` GROUP BY `finance_customer_ledger`.`company_id`, `finance_customer_ledger`.`currency_code` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_dashboard_daily_kpis`
--
DROP TABLE IF EXISTS `vw_dashboard_daily_kpis`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_dashboard_daily_kpis`  AS SELECT `finance_profit_records`.`company_id` AS `company_id`, cast(`finance_profit_records`.`created_at` as date) AS `business_date`, count(0) AS `transactions`, sum(`finance_profit_records`.`revenue_amount`) AS `revenue`, sum(`finance_profit_records`.`cost_amount`) AS `cost`, sum(`finance_profit_records`.`gross_profit`) AS `profit` FROM `finance_profit_records` GROUP BY `finance_profit_records`.`company_id`, cast(`finance_profit_records`.`created_at` as date) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_dashboard_supplier_payables`
--
DROP TABLE IF EXISTS `vw_dashboard_supplier_payables`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_dashboard_supplier_payables`  AS SELECT `finance_supplier_ledger`.`company_id` AS `company_id`, `finance_supplier_ledger`.`currency_code` AS `currency_code`, sum(`finance_supplier_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_supplier_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_supplier_ledger`.`credit_amount` - `finance_supplier_ledger`.`debit_amount`) AS `balance` FROM `finance_supplier_ledger` GROUP BY `finance_supplier_ledger`.`company_id`, `finance_supplier_ledger`.`currency_code` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_employee_attendance_summary`
--
DROP TABLE IF EXISTS `vw_employee_attendance_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_employee_attendance_summary`  AS SELECT `ea`.`company_id` AS `company_id`, `ea`.`employee_id` AS `employee_id`, count(0) AS `attendance_records`, sum(case when `ea`.`status` = 'present' then 1 else 0 end) AS `present_days`, sum(case when `ea`.`status` = 'absent' then 1 else 0 end) AS `absent_days`, sum(case when `ea`.`status` = 'late' then 1 else 0 end) AS `late_days`, sum(`ea`.`worked_hours`) AS `worked_hours`, sum(`ea`.`overtime_hours`) AS `overtime_hours` FROM `employee_attendance` AS `ea` GROUP BY `ea`.`company_id`, `ea`.`employee_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_employee_directory`
--
DROP TABLE IF EXISTS `vw_employee_directory`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_employee_directory`  AS SELECT `e`.`id` AS `id`, `e`.`company_id` AS `company_id`, `e`.`branch_id` AS `branch_id`, `e`.`employee_no` AS `employee_no`, `e`.`first_name` AS `first_name`, `e`.`middle_name` AS `middle_name`, `e`.`last_name` AS `last_name`, `e`.`father_name` AS `father_name`, concat_ws(' ',`e`.`first_name`,`e`.`middle_name`,`e`.`last_name`) AS `full_name`, `e`.`gender` AS `gender`, `e`.`date_of_birth` AS `date_of_birth`, `e`.`phone` AS `phone`, `e`.`whatsapp` AS `whatsapp`, `e`.`email` AS `email`, `d`.`name` AS `department_name`, `p`.`title` AS `position_title`, `e`.`employment_type` AS `employment_type`, `e`.`joining_date` AS `joining_date`, `e`.`leaving_date` AS `leaving_date`, `e`.`basic_salary` AS `basic_salary`, `e`.`salary_currency` AS `salary_currency`, `e`.`status` AS `status`, `e`.`created_at` AS `created_at`, `e`.`updated_at` AS `updated_at` FROM ((`employees` `e` left join `departments` `d` on(`d`.`company_id` = `e`.`company_id` and `d`.`id` = `e`.`department_id`)) left join `positions` `p` on(`p`.`company_id` = `e`.`company_id` and `p`.`id` = `e`.`position_id`)) WHERE `e`.`deleted_at` is null ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_agency_balance`
--
DROP TABLE IF EXISTS `vw_finance_agency_balance`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_agency_balance`  AS SELECT `finance_agency_ledger`.`company_id` AS `company_id`, `finance_agency_ledger`.`agency_id` AS `agency_id`, sum(`finance_agency_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_agency_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_agency_ledger`.`debit_amount` - `finance_agency_ledger`.`credit_amount`) AS `balance` FROM `finance_agency_ledger` GROUP BY `finance_agency_ledger`.`company_id`, `finance_agency_ledger`.`agency_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_agency_statement`
--
DROP TABLE IF EXISTS `vw_finance_agency_statement`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_agency_statement`  AS SELECT `fal`.`company_id` AS `company_id`, `fal`.`branch_id` AS `branch_id`, `fal`.`agency_id` AS `agency_id`, `fal`.`entry_date` AS `entry_date`, `fal`.`reference_type` AS `reference_type`, `fal`.`reference_id` AS `reference_id`, `fal`.`reference_no` AS `reference_no`, `fal`.`debit_amount` AS `debit_amount`, `fal`.`credit_amount` AS `credit_amount`, `fal`.`debit_amount`- `fal`.`credit_amount` AS `net_amount`, `fal`.`currency_code` AS `currency_code`, `fal`.`invoice_id` AS `invoice_id`, `fal`.`payment_id` AS `payment_id`, `fal`.`journal_entry_id` AS `journal_entry_id`, `fal`.`description` AS `description` FROM `finance_agency_ledger` AS `fal` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_agency_statement_summary`
--
DROP TABLE IF EXISTS `vw_finance_agency_statement_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_agency_statement_summary`  AS SELECT `finance_agency_ledger`.`company_id` AS `company_id`, `finance_agency_ledger`.`agency_id` AS `agency_id`, `finance_agency_ledger`.`currency_code` AS `currency_code`, sum(`finance_agency_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_agency_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_agency_ledger`.`debit_amount` - `finance_agency_ledger`.`credit_amount`) AS `net_balance` FROM `finance_agency_ledger` GROUP BY `finance_agency_ledger`.`company_id`, `finance_agency_ledger`.`agency_id`, `finance_agency_ledger`.`currency_code` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_ap_aging_summary`
--
DROP TABLE IF EXISTS `vw_finance_ap_aging_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_ap_aging_summary`  AS SELECT `sb`.`company_id` AS `company_id`, coalesce(sum(case when `sb`.`balance` > 0 then `sb`.`balance` else 0 end),0) AS `total_payable`, coalesce(sum(case when `sb`.`balance` > 0 and (`sb`.`due_date` is null or `sb`.`due_date` >= curdate()) then `sb`.`balance` else 0 end),0) AS `current_amount`, coalesce(sum(case when `sb`.`balance` > 0 and `sb`.`due_date` is not null and to_days(curdate()) - to_days(`sb`.`due_date`) between 1 and 30 then `sb`.`balance` else 0 end),0) AS `days_1_30`, coalesce(sum(case when `sb`.`balance` > 0 and `sb`.`due_date` is not null and to_days(curdate()) - to_days(`sb`.`due_date`) between 31 and 60 then `sb`.`balance` else 0 end),0) AS `days_31_60`, coalesce(sum(case when `sb`.`balance` > 0 and `sb`.`due_date` is not null and to_days(curdate()) - to_days(`sb`.`due_date`) between 61 and 90 then `sb`.`balance` else 0 end),0) AS `days_61_90`, coalesce(sum(case when `sb`.`balance` > 0 and `sb`.`due_date` is not null and to_days(curdate()) - to_days(`sb`.`due_date`) > 90 then `sb`.`balance` else 0 end),0) AS `days_90_plus` FROM (select `sl`.`company_id` AS `company_id`,`sl`.`supplier_id` AS `supplier_id`,sum(`sl`.`credit_amount` - `sl`.`debit_amount`) AS `balance`,max(`i`.`due_date`) AS `due_date` from (`finance_supplier_ledger` `sl` left join `invoices` `i` on(`i`.`company_id` = `sl`.`company_id` and `i`.`id` = `sl`.`invoice_id` and `i`.`deleted_at` is null)) group by `sl`.`company_id`,`sl`.`supplier_id`) AS `sb` GROUP BY `sb`.`company_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_ar_aging_summary`
--
DROP TABLE IF EXISTS `vw_finance_ar_aging_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_ar_aging_summary`  AS SELECT `invoices`.`company_id` AS `company_id`, coalesce(sum(case when `invoices`.`balance_amount` > 0 and (`invoices`.`due_date` is null or `invoices`.`due_date` >= curdate()) then `invoices`.`balance_amount` else 0 end),0) AS `current_amount`, coalesce(sum(case when `invoices`.`balance_amount` > 0 and `invoices`.`due_date` is not null and to_days(curdate()) - to_days(`invoices`.`due_date`) between 1 and 30 then `invoices`.`balance_amount` else 0 end),0) AS `days_1_30`, coalesce(sum(case when `invoices`.`balance_amount` > 0 and `invoices`.`due_date` is not null and to_days(curdate()) - to_days(`invoices`.`due_date`) between 31 and 60 then `invoices`.`balance_amount` else 0 end),0) AS `days_31_60`, coalesce(sum(case when `invoices`.`balance_amount` > 0 and `invoices`.`due_date` is not null and to_days(curdate()) - to_days(`invoices`.`due_date`) between 61 and 90 then `invoices`.`balance_amount` else 0 end),0) AS `days_61_90`, coalesce(sum(case when `invoices`.`balance_amount` > 0 and `invoices`.`due_date` is not null and to_days(curdate()) - to_days(`invoices`.`due_date`) > 90 then `invoices`.`balance_amount` else 0 end),0) AS `days_90_plus`, coalesce(sum(case when `invoices`.`balance_amount` > 0 then `invoices`.`balance_amount` else 0 end),0) AS `total_receivable` FROM `invoices` WHERE `invoices`.`deleted_at` is null AND `invoices`.`status` not in ('cancelled','refunded') GROUP BY `invoices`.`company_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_balance_sheet`
--
DROP TABLE IF EXISTS `vw_finance_balance_sheet`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_balance_sheet`  AS SELECT `jl`.`company_id` AS `company_id`, `je`.`branch_id` AS `branch_id`, `ca`.`account_type` AS `account_type`, `ca`.`account_code` AS `account_code`, `ca`.`account_name` AS `account_name`, sum(case when `ca`.`account_type` in ('asset','expense') then `jl`.`debit_amount` - `jl`.`credit_amount` when `ca`.`account_type` in ('liability','equity','revenue') then `jl`.`credit_amount` - `jl`.`debit_amount` else 0 end) AS `balance` FROM ((`journal_lines` `jl` join `journal_entries` `je` on(`je`.`company_id` = `jl`.`company_id` and `je`.`id` = `jl`.`journal_entry_id`)) join `finance_chart_accounts` `ca` on(`ca`.`company_id` = `jl`.`company_id` and `ca`.`id` = `jl`.`chart_account_id`)) WHERE `je`.`status` = 'posted' GROUP BY `jl`.`company_id`, `je`.`branch_id`, `ca`.`account_type`, `ca`.`account_code`, `ca`.`account_name` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_cash_bank`
--
DROP TABLE IF EXISTS `vw_finance_cash_bank`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_cash_bank`  AS SELECT `fa`.`company_id` AS `company_id`, `fa`.`id` AS `finance_account_id`, `fa`.`account_no` AS `account_no`, `fa`.`name` AS `name`, `fa`.`account_type` AS `account_type`, `fa`.`currency_code` AS `currency_code`, `fa`.`opening_balance` AS `opening_balance`, coalesce(sum(case when `p`.`payment_type` = 'receipt' then `p`.`amount` when `p`.`payment_type` in ('payment','refund') then -`p`.`amount` else 0 end),0) AS `movement_amount`, `fa`.`opening_balance`+ coalesce(sum(case when `p`.`payment_type` = 'receipt' then `p`.`amount` when `p`.`payment_type` in ('payment','refund') then -`p`.`amount` else 0 end),0) AS `calculated_balance` FROM (`finance_accounts` `fa` left join `payments` `p` on(`p`.`company_id` = `fa`.`company_id` and `p`.`finance_account_id` = `fa`.`id` and `p`.`status` = 'posted' and `p`.`deleted_at` is null)) WHERE `fa`.`account_type` in ('cash','bank') GROUP BY `fa`.`company_id`, `fa`.`id`, `fa`.`account_no`, `fa`.`name`, `fa`.`account_type`, `fa`.`currency_code`, `fa`.`opening_balance` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_customer_balance`
--
DROP TABLE IF EXISTS `vw_finance_customer_balance`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_customer_balance`  AS SELECT `finance_customer_ledger`.`company_id` AS `company_id`, `finance_customer_ledger`.`customer_id` AS `customer_id`, `finance_customer_ledger`.`debtor_id` AS `debtor_id`, sum(`finance_customer_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_customer_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_customer_ledger`.`debit_amount` - `finance_customer_ledger`.`credit_amount`) AS `balance` FROM `finance_customer_ledger` GROUP BY `finance_customer_ledger`.`company_id`, `finance_customer_ledger`.`customer_id`, `finance_customer_ledger`.`debtor_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_customer_statement`
--
DROP TABLE IF EXISTS `vw_finance_customer_statement`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_customer_statement`  AS SELECT `fcl`.`company_id` AS `company_id`, `fcl`.`branch_id` AS `branch_id`, `fcl`.`customer_id` AS `customer_id`, `fcl`.`debtor_id` AS `debtor_id`, `fcl`.`entry_date` AS `entry_date`, `fcl`.`reference_type` AS `reference_type`, `fcl`.`reference_id` AS `reference_id`, `fcl`.`reference_no` AS `reference_no`, `fcl`.`debit_amount` AS `debit_amount`, `fcl`.`credit_amount` AS `credit_amount`, `fcl`.`debit_amount`- `fcl`.`credit_amount` AS `net_amount`, `fcl`.`currency_code` AS `currency_code`, `fcl`.`invoice_id` AS `invoice_id`, `fcl`.`payment_id` AS `payment_id`, `fcl`.`journal_entry_id` AS `journal_entry_id`, `fcl`.`description` AS `description` FROM `finance_customer_ledger` AS `fcl` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_expenses`
--
DROP TABLE IF EXISTS `vw_finance_expenses`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_expenses`  AS SELECT `jl`.`company_id` AS `company_id`, `je`.`branch_id` AS `branch_id`, `ca`.`account_code` AS `account_code`, `ca`.`account_name` AS `account_name`, sum(`jl`.`debit_amount` - `jl`.`credit_amount`) AS `expense_amount` FROM ((`journal_lines` `jl` join `journal_entries` `je` on(`je`.`company_id` = `jl`.`company_id` and `je`.`id` = `jl`.`journal_entry_id`)) join `finance_chart_accounts` `ca` on(`ca`.`company_id` = `jl`.`company_id` and `ca`.`id` = `jl`.`chart_account_id`)) WHERE `je`.`status` = 'posted' AND `ca`.`account_type` = 'expense' GROUP BY `jl`.`company_id`, `je`.`branch_id`, `ca`.`account_code`, `ca`.`account_name` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_general_ledger`
--
DROP TABLE IF EXISTS `vw_finance_general_ledger`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_general_ledger`  AS SELECT `jl`.`company_id` AS `company_id`, `je`.`branch_id` AS `branch_id`, `je`.`entry_date` AS `entry_date`, `je`.`entry_no` AS `entry_no`, `je`.`reference_type` AS `reference_type`, `je`.`reference_id` AS `reference_id`, `je`.`reference_no` AS `reference_no`, `ca`.`account_code` AS `account_code`, `ca`.`account_name` AS `account_name`, `jl`.`description` AS `description`, `jl`.`debit_amount` AS `debit_amount`, `jl`.`credit_amount` AS `credit_amount`, `jl`.`currency_code` AS `currency_code`, `je`.`status` AS `status` FROM ((`journal_lines` `jl` join `journal_entries` `je` on(`je`.`company_id` = `jl`.`company_id` and `je`.`id` = `jl`.`journal_entry_id`)) join `finance_chart_accounts` `ca` on(`ca`.`company_id` = `jl`.`company_id` and `ca`.`id` = `jl`.`chart_account_id`)) ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_invoice_aging`
--
DROP TABLE IF EXISTS `vw_finance_invoice_aging`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_invoice_aging`  AS SELECT `i`.`company_id` AS `company_id`, `i`.`branch_id` AS `branch_id`, `i`.`id` AS `invoice_id`, `i`.`invoice_no` AS `invoice_no`, `i`.`invoice_date` AS `invoice_date`, `i`.`due_date` AS `due_date`, `i`.`customer_id` AS `customer_id`, `i`.`debtor_id` AS `debtor_id`, `i`.`total_amount` AS `total_amount`, `i`.`paid_amount` AS `paid_amount`, `i`.`balance_amount` AS `balance_amount`, CASE WHEN `i`.`balance_amount` <= 0 THEN 'paid' WHEN `i`.`due_date` is null THEN 'no_due_date' WHEN `i`.`due_date` >= curdate() THEN 'current' WHEN to_days(curdate()) - to_days(`i`.`due_date`) between 1 and 30 THEN '1_30' WHEN to_days(curdate()) - to_days(`i`.`due_date`) between 31 and 60 THEN '31_60' WHEN to_days(curdate()) - to_days(`i`.`due_date`) between 61 and 90 THEN '61_90' ELSE '90_plus' END AS `aging_bucket` FROM `invoices` AS `i` WHERE `i`.`deleted_at` is null ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_payables_summary`
--
DROP TABLE IF EXISTS `vw_finance_payables_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_payables_summary`  AS SELECT `finance_supplier_ledger`.`company_id` AS `company_id`, `finance_supplier_ledger`.`currency_code` AS `currency_code`, sum(`finance_supplier_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_supplier_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_supplier_ledger`.`credit_amount` - `finance_supplier_ledger`.`debit_amount`) AS `payable_balance` FROM `finance_supplier_ledger` GROUP BY `finance_supplier_ledger`.`company_id`, `finance_supplier_ledger`.`currency_code` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_payment_status`
--
DROP TABLE IF EXISTS `vw_finance_payment_status`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_payment_status`  AS SELECT `p`.`company_id` AS `company_id`, `p`.`branch_id` AS `branch_id`, `p`.`id` AS `payment_id`, `p`.`payment_no` AS `payment_no`, `p`.`payment_type` AS `payment_type`, `p`.`payment_date` AS `payment_date`, `p`.`amount` AS `amount`, `p`.`currency_code` AS `currency_code`, `p`.`status` AS `status`, `p`.`journal_entry_id` AS `journal_entry_id`, coalesce(sum(`pa`.`allocated_amount`),0) AS `allocated_amount`, `p`.`amount`- coalesce(sum(`pa`.`allocated_amount`),0) AS `unallocated_amount` FROM (`payments` `p` left join `payment_allocations` `pa` on(`pa`.`company_id` = `p`.`company_id` and `pa`.`payment_id` = `p`.`id`)) GROUP BY `p`.`company_id`, `p`.`branch_id`, `p`.`id`, `p`.`payment_no`, `p`.`payment_type`, `p`.`payment_date`, `p`.`amount`, `p`.`currency_code`, `p`.`status`, `p`.`journal_entry_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_profit_loss`
--
DROP TABLE IF EXISTS `vw_finance_profit_loss`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_profit_loss`  AS SELECT `jl`.`company_id` AS `company_id`, `je`.`branch_id` AS `branch_id`, coalesce(sum(case when `ca`.`account_type` = 'revenue' then `jl`.`credit_amount` - `jl`.`debit_amount` else 0 end),0) AS `total_revenue`, coalesce(sum(case when `ca`.`account_type` = 'expense' then `jl`.`debit_amount` - `jl`.`credit_amount` else 0 end),0) AS `total_expenses`, coalesce(sum(case when `ca`.`account_type` = 'revenue' then `jl`.`credit_amount` - `jl`.`debit_amount` when `ca`.`account_type` = 'expense' then -(`jl`.`debit_amount` - `jl`.`credit_amount`) else 0 end),0) AS `net_profit` FROM ((`journal_lines` `jl` join `journal_entries` `je` on(`je`.`company_id` = `jl`.`company_id` and `je`.`id` = `jl`.`journal_entry_id`)) join `finance_chart_accounts` `ca` on(`ca`.`company_id` = `jl`.`company_id` and `ca`.`id` = `jl`.`chart_account_id`)) WHERE `je`.`status` = 'posted' GROUP BY `jl`.`company_id`, `je`.`branch_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_receivables_summary`
--
DROP TABLE IF EXISTS `vw_finance_receivables_summary`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_receivables_summary`  AS SELECT `finance_customer_ledger`.`company_id` AS `company_id`, `finance_customer_ledger`.`currency_code` AS `currency_code`, sum(`finance_customer_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_customer_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_customer_ledger`.`debit_amount` - `finance_customer_ledger`.`credit_amount`) AS `receivable_balance` FROM `finance_customer_ledger` GROUP BY `finance_customer_ledger`.`company_id`, `finance_customer_ledger`.`currency_code` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_revenue`
--
DROP TABLE IF EXISTS `vw_finance_revenue`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_revenue`  AS SELECT `jl`.`company_id` AS `company_id`, `je`.`branch_id` AS `branch_id`, `ca`.`account_code` AS `account_code`, `ca`.`account_name` AS `account_name`, sum(`jl`.`credit_amount` - `jl`.`debit_amount`) AS `revenue_amount` FROM ((`journal_lines` `jl` join `journal_entries` `je` on(`je`.`company_id` = `jl`.`company_id` and `je`.`id` = `jl`.`journal_entry_id`)) join `finance_chart_accounts` `ca` on(`ca`.`company_id` = `jl`.`company_id` and `ca`.`id` = `jl`.`chart_account_id`)) WHERE `je`.`status` = 'posted' AND `ca`.`account_type` = 'revenue' GROUP BY `jl`.`company_id`, `je`.`branch_id`, `ca`.`account_code`, `ca`.`account_name` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_service_profit`
--
DROP TABLE IF EXISTS `vw_finance_service_profit`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_service_profit`  AS SELECT `finance_profit_records`.`company_id` AS `company_id`, `finance_profit_records`.`transaction_type` AS `transaction_type`, count(0) AS `transaction_count`, coalesce(sum(`finance_profit_records`.`revenue_amount`),0) AS `revenue`, coalesce(sum(`finance_profit_records`.`cost_amount`),0) AS `cost`, coalesce(sum(`finance_profit_records`.`gross_profit`),0) AS `gross_profit` FROM `finance_profit_records` GROUP BY `finance_profit_records`.`company_id`, `finance_profit_records`.`transaction_type` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_supplier_balance`
--
DROP TABLE IF EXISTS `vw_finance_supplier_balance`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_supplier_balance`  AS SELECT `finance_supplier_ledger`.`company_id` AS `company_id`, `finance_supplier_ledger`.`supplier_id` AS `supplier_id`, sum(`finance_supplier_ledger`.`debit_amount`) AS `total_debit`, sum(`finance_supplier_ledger`.`credit_amount`) AS `total_credit`, sum(`finance_supplier_ledger`.`credit_amount` - `finance_supplier_ledger`.`debit_amount`) AS `balance` FROM `finance_supplier_ledger` GROUP BY `finance_supplier_ledger`.`company_id`, `finance_supplier_ledger`.`supplier_id` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_supplier_statement`
--
DROP TABLE IF EXISTS `vw_finance_supplier_statement`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_supplier_statement`  AS SELECT `fsl`.`company_id` AS `company_id`, `fsl`.`branch_id` AS `branch_id`, `fsl`.`supplier_id` AS `supplier_id`, `fsl`.`entry_date` AS `entry_date`, `fsl`.`reference_type` AS `reference_type`, `fsl`.`reference_id` AS `reference_id`, `fsl`.`reference_no` AS `reference_no`, `fsl`.`debit_amount` AS `debit_amount`, `fsl`.`credit_amount` AS `credit_amount`, `fsl`.`credit_amount`- `fsl`.`debit_amount` AS `payable_change`, `fsl`.`currency_code` AS `currency_code`, `fsl`.`invoice_id` AS `invoice_id`, `fsl`.`payment_id` AS `payment_id`, `fsl`.`journal_entry_id` AS `journal_entry_id`, `fsl`.`description` AS `description` FROM `finance_supplier_ledger` AS `fsl` ;

-- --------------------------------------------------------

--
-- Structure for view `vw_finance_trial_balance`
--
DROP TABLE IF EXISTS `vw_finance_trial_balance`;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `vw_finance_trial_balance`  AS SELECT `jl`.`company_id` AS `company_id`, `jl`.`chart_account_id` AS `chart_account_id`, `ca`.`account_code` AS `account_code`, `ca`.`account_name` AS `account_name`, `ca`.`account_type` AS `account_type`, sum(`jl`.`debit_amount`) AS `total_debit`, sum(`jl`.`credit_amount`) AS `total_credit`, sum(`jl`.`debit_amount` - `jl`.`credit_amount`) AS `balance` FROM ((`journal_lines` `jl` join `journal_entries` `je` on(`je`.`company_id` = `jl`.`company_id` and `je`.`id` = `jl`.`journal_entry_id`)) join `finance_chart_accounts` `ca` on(`ca`.`company_id` = `jl`.`company_id` and `ca`.`id` = `jl`.`chart_account_id`)) WHERE `je`.`status` = 'posted' GROUP BY `jl`.`company_id`, `jl`.`chart_account_id`, `ca`.`account_code`, `ca`.`account_name`, `ca`.`account_type` ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `account_mappings`
--
ALTER TABLE `account_mappings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_account_mappings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_account_mapping_company_module_key` (`company_id`,`module`,`mapping_key`),
  ADD KEY `idx_account_mappings_company_account` (`company_id`,`account_id`),
  ADD KEY `idx_account_mappings_company_status` (`company_id`,`status`),
  ADD KEY `idx_account_mappings_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_account_mappings_company_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `agencies`
--
ALTER TABLE `agencies`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_agencies_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_agency_no_company` (`company_id`,`agency_no`),
  ADD KEY `idx_agencies_company` (`company_id`),
  ADD KEY `idx_agencies_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_agencies_phone` (`company_id`,`phone`),
  ADD KEY `idx_agencies_type` (`company_id`,`agency_type`),
  ADD KEY `idx_agencies_city` (`city_id`),
  ADD KEY `idx_agencies_country` (`country_id`),
  ADD KEY `idx_agencies_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_agencies_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `airlines`
--
ALTER TABLE `airlines`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_airline_code` (`code`);

--
-- Indexes for table `airports`
--
ALTER TABLE `airports`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_airport_code` (`code`),
  ADD KEY `idx_airport_city` (`city_id`),
  ADD KEY `idx_airport_country` (`country_id`);

--
-- Indexes for table `audit_logs`
--
ALTER TABLE `audit_logs`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_audit_company` (`company_id`),
  ADD KEY `idx_audit_company_user` (`company_id`,`user_id`),
  ADD KEY `idx_audit_record` (`company_id`,`table_name`,`record_id`),
  ADD KEY `idx_audit_action` (`company_id`,`action`),
  ADD KEY `idx_audit_created` (`company_id`,`created_at`);

--
-- Indexes for table `backup_restore_history`
--
ALTER TABLE `backup_restore_history`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_backup_restore_company` (`company_id`),
  ADD KEY `idx_backup_restore_backup` (`backup_id`),
  ADD KEY `fk_backup_restore_user` (`company_id`,`performed_by`);

--
-- Indexes for table `bookings`
--
ALTER TABLE `bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_bookings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_booking_no_company` (`company_id`,`booking_no`),
  ADD KEY `idx_bookings_company` (`company_id`),
  ADD KEY `idx_bookings_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_bookings_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_bookings_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_bookings_agency` (`company_id`,`agency_id`),
  ADD KEY `idx_bookings_status` (`company_id`,`status`),
  ADD KEY `idx_bookings_travel_date` (`company_id`,`travel_date`),
  ADD KEY `idx_bookings_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_bookings_company_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `booking_passengers`
--
ALTER TABLE `booking_passengers`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_booking_passenger_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_booking_passenger_booking` (`company_id`,`booking_id`),
  ADD KEY `idx_booking_passenger_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_booking_passenger_passport` (`company_id`,`passport_no`),
  ADD KEY `fk_booking_passenger_nationality` (`nationality_country_id`);

--
-- Indexes for table `branches`
--
ALTER TABLE `branches`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_branches_company_code` (`company_id`,`code`),
  ADD UNIQUE KEY `uq_branches_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_branch_company` (`company_id`),
  ADD KEY `idx_branch_city` (`city_id`),
  ADD KEY `idx_branch_country` (`country_id`),
  ADD KEY `idx_branch_currency` (`currency_code`);

--
-- Indexes for table `cities`
--
ALTER TABLE `cities`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_city_country` (`country_id`);

--
-- Indexes for table `companies`
--
ALTER TABLE `companies`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `code` (`code`),
  ADD KEY `idx_companies_status` (`status`),
  ADD KEY `idx_companies_default_currency` (`default_currency_code`),
  ADD KEY `idx_companies_default_language` (`default_language_code`);

--
-- Indexes for table `company_branding`
--
ALTER TABLE `company_branding`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_company_branding_company` (`company_id`),
  ADD UNIQUE KEY `uq_company_branding_company_id_id` (`company_id`,`id`);

--
-- Indexes for table `company_currencies`
--
ALTER TABLE `company_currencies`
  ADD PRIMARY KEY (`company_id`,`currency_code`),
  ADD KEY `idx_company_currencies_currency` (`currency_code`);

--
-- Indexes for table `company_settings`
--
ALTER TABLE `company_settings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_company_setting` (`company_id`,`setting_key`),
  ADD UNIQUE KEY `uq_company_settings_company_id_id` (`company_id`,`id`);

--
-- Indexes for table `countries`
--
ALTER TABLE `countries`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_country_iso2` (`iso2`),
  ADD UNIQUE KEY `uq_country_iso3` (`iso3`);

--
-- Indexes for table `currencies`
--
ALTER TABLE `currencies`
  ADD PRIMARY KEY (`code`);

--
-- Indexes for table `customers`
--
ALTER TABLE `customers`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_customers_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_customer_no_company` (`company_id`,`customer_no`),
  ADD KEY `idx_customers_company` (`company_id`),
  ADD KEY `idx_customers_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_customers_phone` (`company_id`,`phone`),
  ADD KEY `idx_customers_national_id` (`company_id`,`national_id`),
  ADD KEY `idx_customers_name` (`company_id`,`last_name`,`first_name`),
  ADD KEY `idx_customers_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_customers_company_updated_by` (`company_id`,`updated_by`),
  ADD KEY `fk_customer_nationality` (`nationality_country_id`);

--
-- Indexes for table `customer_addresses`
--
ALTER TABLE `customer_addresses`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_customer_address_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_customer_address_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_customer_address_city` (`city_id`),
  ADD KEY `idx_customer_address_country` (`country_id`);

--
-- Indexes for table `customer_documents`
--
ALTER TABLE `customer_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_customer_document_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_customer_documents_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_customer_documents_type` (`company_id`,`document_type`),
  ADD KEY `idx_customer_documents_expiry` (`company_id`,`expiry_date`),
  ADD KEY `idx_customer_documents_verified_by` (`company_id`,`verified_by`),
  ADD KEY `idx_customer_documents_uploaded_by` (`company_id`,`uploaded_by`);

--
-- Indexes for table `debtors`
--
ALTER TABLE `debtors`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_debtors_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_debtor_no_company` (`company_id`,`debtor_no`),
  ADD KEY `idx_debtors_company` (`company_id`),
  ADD KEY `idx_debtors_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_debtors_phone` (`company_id`,`phone`),
  ADD KEY `idx_debtors_national_id` (`company_id`,`national_id`),
  ADD KEY `idx_debtors_passport` (`company_id`,`passport_no`),
  ADD KEY `idx_debtors_name` (`company_id`,`last_name`,`first_name`),
  ADD KEY `idx_debtors_company_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `debtor_addresses`
--
ALTER TABLE `debtor_addresses`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_debtor_address_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_debtor_address_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_debtor_address_city` (`city_id`),
  ADD KEY `idx_debtor_address_country` (`country_id`);

--
-- Indexes for table `debtor_guarantors`
--
ALTER TABLE `debtor_guarantors`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_debtor_guarantor_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_debtor_guarantor_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_debtor_guarantor_phone` (`company_id`,`phone`);

--
-- Indexes for table `departments`
--
ALTER TABLE `departments`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_departments_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_departments_code` (`company_id`,`code`),
  ADD KEY `idx_departments_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_departments_manager` (`company_id`,`manager_employee_id`),
  ADD KEY `fk_departments_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_departments_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `discounts`
--
ALTER TABLE `discounts`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_discounts_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_discount_code` (`company_id`,`code`),
  ADD KEY `idx_discounts_company` (`company_id`),
  ADD KEY `idx_discounts_dates` (`company_id`,`start_date`,`end_date`);

--
-- Indexes for table `drivers`
--
ALTER TABLE `drivers`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_drivers_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_driver_code_company` (`company_id`,`driver_code`),
  ADD UNIQUE KEY `uq_driver_license_company` (`company_id`,`license_no`),
  ADD KEY `idx_drivers_company` (`company_id`),
  ADD KEY `idx_drivers_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_drivers_phone` (`company_id`,`phone`),
  ADD KEY `idx_drivers_national_id` (`company_id`,`national_id`),
  ADD KEY `idx_drivers_passport` (`company_id`,`passport_no`),
  ADD KEY `idx_drivers_status` (`company_id`,`status`),
  ADD KEY `idx_drivers_city` (`city_id`),
  ADD KEY `idx_drivers_country` (`country_id`),
  ADD KEY `fk_drivers_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_drivers_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `employees`
--
ALTER TABLE `employees`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_employees_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_employees_no` (`company_id`,`employee_no`),
  ADD KEY `idx_employees_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_employees_department` (`company_id`,`department_id`),
  ADD KEY `idx_employees_position` (`company_id`,`position_id`),
  ADD KEY `idx_employees_manager` (`company_id`,`manager_id`),
  ADD KEY `idx_employees_passport` (`company_id`,`passport_no`),
  ADD KEY `idx_employees_national_id` (`company_id`,`national_id`),
  ADD KEY `idx_employees_status` (`company_id`,`status`),
  ADD KEY `fk_employees_currency` (`salary_currency`),
  ADD KEY `fk_employees_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_employees_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `employee_attendance`
--
ALTER TABLE `employee_attendance`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_employee_attendance_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_employee_attendance_date` (`company_id`,`employee_id`,`attendance_date`),
  ADD KEY `idx_employee_attendance_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_employee_attendance_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `employee_contracts`
--
ALTER TABLE `employee_contracts`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_employee_contracts_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_employee_contract_no` (`company_id`,`contract_no`),
  ADD KEY `idx_employee_contract_employee` (`company_id`,`employee_id`),
  ADD KEY `fk_employee_contract_currency` (`currency_code`),
  ADD KEY `fk_employee_contract_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `employee_documents`
--
ALTER TABLE `employee_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_employee_documents_company_id` (`company_id`,`id`),
  ADD KEY `idx_employee_documents_employee` (`company_id`,`employee_id`),
  ADD KEY `idx_employee_documents_expiry` (`company_id`,`expiry_date`),
  ADD KEY `fk_employee_documents_verified_by` (`company_id`,`verified_by`),
  ADD KEY `fk_employee_documents_uploaded_by` (`company_id`,`uploaded_by`);

--
-- Indexes for table `employee_leaves`
--
ALTER TABLE `employee_leaves`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_employee_leaves_company_id` (`company_id`,`id`),
  ADD KEY `idx_employee_leaves_employee` (`company_id`,`employee_id`),
  ADD KEY `idx_employee_leaves_dates` (`company_id`,`start_date`,`end_date`),
  ADD KEY `fk_employee_leaves_approved_by` (`company_id`,`approved_by`),
  ADD KEY `fk_employee_leaves_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `employee_salary_payments`
--
ALTER TABLE `employee_salary_payments`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_salary_payment_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_salary_payment_no` (`company_id`,`payment_no`),
  ADD UNIQUE KEY `uq_salary_employee_month` (`company_id`,`employee_id`,`salary_month`),
  ADD KEY `idx_salary_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_salary_finance_account` (`company_id`,`finance_account_id`),
  ADD KEY `idx_salary_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_salary_currency` (`currency_code`),
  ADD KEY `fk_salary_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_salary_approved_by` (`company_id`,`approved_by`);

--
-- Indexes for table `employee_user_accounts`
--
ALTER TABLE `employee_user_accounts`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_employee_user_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_employee_user_employee` (`company_id`,`employee_id`),
  ADD UNIQUE KEY `uq_employee_user_user` (`company_id`,`user_id`);

--
-- Indexes for table `exchange_rates`
--
ALTER TABLE `exchange_rates`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_exchange_rate_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_exchange_rate` (`company_id`,`from_currency_code`,`to_currency_code`,`effective_date`),
  ADD KEY `idx_exchange_company` (`company_id`),
  ADD KEY `idx_exchange_from` (`company_id`,`from_currency_code`),
  ADD KEY `idx_exchange_to` (`company_id`,`to_currency_code`),
  ADD KEY `fk_exchange_from_currency` (`from_currency_code`),
  ADD KEY `fk_exchange_to_currency` (`to_currency_code`);

--
-- Indexes for table `expenses`
--
ALTER TABLE `expenses`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_exp_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_exp_no` (`company_id`,`expense_no`),
  ADD KEY `idx_exp_date` (`company_id`,`expense_date`),
  ADD KEY `idx_exp_supplier` (`company_id`,`supplier_id`),
  ADD KEY `fk_exp_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_exp_account` (`company_id`,`expense_account_id`),
  ADD KEY `fk_exp_payment_account` (`company_id`,`payment_account_id`),
  ADD KEY `fk_exp_currency` (`currency_code`),
  ADD KEY `fk_exp_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_exp_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_exp_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `family_members`
--
ALTER TABLE `family_members`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_family_member_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_family_member_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_family_member_passport` (`company_id`,`passport_no`);

--
-- Indexes for table `finance_accounts`
--
ALTER TABLE `finance_accounts`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fa_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_fa_account_no` (`company_id`,`account_no`),
  ADD KEY `idx_fa_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fa_chart` (`company_id`,`chart_account_id`),
  ADD KEY `fk_fa_currency` (`currency_code`),
  ADD KEY `fk_fa_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_fa_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `finance_agency_ledger`
--
ALTER TABLE `finance_agency_ledger`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fal_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_fal_agency` (`company_id`,`agency_id`),
  ADD KEY `fk_fal_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fal_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_fal_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_fal_payment` (`company_id`,`payment_id`),
  ADD KEY `fk_fal_currency` (`currency_code`);

--
-- Indexes for table `finance_approvals`
--
ALTER TABLE `finance_approvals`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fap_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_fap_document` (`company_id`,`document_type`,`document_id`),
  ADD KEY `fk_fap_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fap_requested_by` (`company_id`,`requested_by`),
  ADD KEY `fk_fap_approved_by` (`company_id`,`approved_by`);

--
-- Indexes for table `finance_audit_log`
--
ALTER TABLE `finance_audit_log`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_fal_audit_company_date` (`company_id`,`created_at`),
  ADD KEY `idx_fal_audit_document` (`company_id`,`document_type`,`document_id`),
  ADD KEY `fk_fal_audit_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fal_audit_user` (`company_id`,`user_id`);

--
-- Indexes for table `finance_chart_accounts`
--
ALTER TABLE `finance_chart_accounts`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fca_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_fca_code` (`company_id`,`account_code`),
  ADD KEY `idx_fca_parent` (`company_id`,`parent_account_id`),
  ADD KEY `idx_fca_type` (`company_id`,`account_type`),
  ADD KEY `fk_fca_currency` (`currency_code`),
  ADD KEY `fk_fca_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_fca_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `finance_customer_ledger`
--
ALTER TABLE `finance_customer_ledger`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fcl_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_fcl_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_fcl_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_fcl_reference` (`company_id`,`reference_type`,`reference_id`),
  ADD KEY `fk_fcl_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fcl_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_fcl_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_fcl_payment` (`company_id`,`payment_id`),
  ADD KEY `fk_fcl_currency` (`currency_code`);

--
-- Indexes for table `finance_fiscal_years`
--
ALTER TABLE `finance_fiscal_years`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_finance_fiscal_year_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_finance_fiscal_year_name` (`company_id`,`name`),
  ADD KEY `idx_finance_fiscal_year_dates` (`company_id`,`start_date`,`end_date`),
  ADD KEY `fk_fy_closed_by` (`company_id`,`closed_by`),
  ADD KEY `fk_fy_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_fy_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `finance_periods`
--
ALTER TABLE `finance_periods`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_finance_period_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_finance_period_year_no` (`company_id`,`fiscal_year_id`,`period_no`),
  ADD KEY `fk_fp_closed_by` (`company_id`,`closed_by`);

--
-- Indexes for table `finance_profit_records`
--
ALTER TABLE `finance_profit_records`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fpr_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_fpr_transaction` (`company_id`,`transaction_type`,`transaction_id`),
  ADD KEY `fk_fpr_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fpr_currency` (`currency_code`),
  ADD KEY `fk_fpr_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_fpr_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `finance_refunds`
--
ALTER TABLE `finance_refunds`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fr_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_fr_no` (`company_id`,`refund_no`),
  ADD KEY `fk_fr_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fr_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_fr_payment` (`company_id`,`payment_id`),
  ADD KEY `fk_fr_customer` (`company_id`,`customer_id`),
  ADD KEY `fk_fr_debtor` (`company_id`,`debtor_id`),
  ADD KEY `fk_fr_currency` (`currency_code`),
  ADD KEY `fk_fr_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_fr_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `finance_service_costs`
--
ALTER TABLE `finance_service_costs`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fsc_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_fsc_service` (`company_id`,`service_type`,`service_id`),
  ADD KEY `idx_fsc_supplier` (`company_id`,`supplier_id`),
  ADD KEY `fk_fsc_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fsc_currency` (`currency_code`),
  ADD KEY `fk_fsc_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_fsc_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_fsc_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `finance_supplier_ledger`
--
ALTER TABLE `finance_supplier_ledger`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_fsl_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_fsl_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_fsl_reference` (`company_id`,`reference_type`,`reference_id`),
  ADD KEY `fk_fsl_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_fsl_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_fsl_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_fsl_payment` (`company_id`,`payment_id`),
  ADD KEY `fk_fsl_currency` (`currency_code`);

--
-- Indexes for table `finance_transaction_links`
--
ALTER TABLE `finance_transaction_links`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ftl_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_ftl_source` (`company_id`,`transaction_type`,`transaction_id`),
  ADD KEY `fk_ftl_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_ftl_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_ftl_payment` (`company_id`,`payment_id`),
  ADD KEY `fk_ftl_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_ftl_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `foreign_visitors`
--
ALTER TABLE `foreign_visitors`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_foreign_visitors_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_foreign_visitor_no_company` (`company_id`,`visitor_no`),
  ADD UNIQUE KEY `uq_foreign_passport_company` (`company_id`,`passport_no`),
  ADD KEY `idx_foreign_visitors_company` (`company_id`),
  ADD KEY `idx_foreign_visitors_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_foreign_visitors_nationality` (`nationality_country_id`),
  ADD KEY `idx_foreign_visitors_passport` (`company_id`,`passport_no`),
  ADD KEY `idx_foreign_visitors_phone` (`company_id`,`phone`),
  ADD KEY `idx_foreign_visitors_purpose` (`company_id`,`purpose`),
  ADD KEY `idx_foreign_visitors_status` (`company_id`,`status`),
  ADD KEY `fk_foreign_visitors_passport_country` (`passport_issue_country_id`),
  ADD KEY `fk_foreign_visitors_country` (`country_id`),
  ADD KEY `fk_foreign_visitors_city` (`city_id`),
  ADD KEY `fk_foreign_visitors_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_foreign_visitors_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `foreign_visitor_documents`
--
ALTER TABLE `foreign_visitor_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_foreign_visitor_documents_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_fvd_company` (`company_id`),
  ADD KEY `idx_fvd_visitor` (`company_id`,`visitor_id`),
  ADD KEY `idx_fvd_type` (`company_id`,`document_type`),
  ADD KEY `idx_fvd_status` (`company_id`,`verification_status`),
  ADD KEY `idx_fvd_expiry` (`company_id`,`expiry_date`),
  ADD KEY `fk_fvd_verified_by_tenant` (`company_id`,`verified_by`),
  ADD KEY `fk_fvd_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_fvd_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `hotels`
--
ALTER TABLE `hotels`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_hotels_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_hotel_code_company` (`company_id`,`hotel_code`),
  ADD KEY `idx_hotels_company` (`company_id`),
  ADD KEY `idx_hotels_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_hotels_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_hotels_city` (`city_id`),
  ADD KEY `idx_hotels_country` (`country_id`),
  ADD KEY `idx_hotels_distance` (`company_id`,`distance_category`),
  ADD KEY `idx_hotels_status` (`company_id`,`status`),
  ADD KEY `fk_hotels_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_hotels_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `hotel_bookings`
--
ALTER TABLE `hotel_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_hotel_bookings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_hotel_reservation_company` (`company_id`,`reservation_no`),
  ADD KEY `idx_hotel_booking_company` (`company_id`),
  ADD KEY `idx_hotel_booking_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_hotel_booking_booking` (`company_id`,`booking_id`),
  ADD KEY `idx_hotel_booking_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_hotel_booking_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_hotel_booking_hotel` (`company_id`,`hotel_id`),
  ADD KEY `idx_hotel_booking_room` (`company_id`,`room_type_id`),
  ADD KEY `idx_hotel_booking_checkin` (`company_id`,`check_in`),
  ADD KEY `idx_hotel_booking_checkout` (`company_id`,`check_out`),
  ADD KEY `idx_hotel_booking_status` (`company_id`,`status`),
  ADD KEY `fk_hotel_booking_currency` (`currency_code`),
  ADD KEY `fk_hotel_booking_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_hotel_booking_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `hotel_room_types`
--
ALTER TABLE `hotel_room_types`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_hotel_room_types_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_hotel_room_code_company` (`company_id`,`hotel_id`,`room_code`),
  ADD KEY `idx_hotel_room_company` (`company_id`),
  ADD KEY `idx_hotel_room_hotel` (`company_id`,`hotel_id`),
  ADD KEY `idx_hotel_room_status` (`company_id`,`status`),
  ADD KEY `fk_hotel_room_currency` (`currency_code`),
  ADD KEY `fk_hotel_room_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_hotel_room_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `interpreters`
--
ALTER TABLE `interpreters`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_interpreters_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_interpreter_no_company` (`company_id`,`interpreter_no`),
  ADD UNIQUE KEY `uq_interpreter_national_id_company` (`company_id`,`national_id`),
  ADD KEY `idx_interpreters_company` (`company_id`),
  ADD KEY `idx_interpreters_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_interpreters_phone` (`company_id`,`phone`),
  ADD KEY `idx_interpreters_status` (`company_id`,`status`),
  ADD KEY `idx_interpreters_nationality` (`nationality_country_id`),
  ADD KEY `idx_interpreters_city` (`city_id`),
  ADD KEY `fk_interpreters_country` (`country_id`),
  ADD KEY `fk_interpreters_approved_by_tenant` (`company_id`,`approved_by`),
  ADD KEY `fk_interpreters_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_interpreters_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `interpreter_assignments`
--
ALTER TABLE `interpreter_assignments`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_interpreter_assignments_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_interpreter_assignment_no_company` (`company_id`,`assignment_no`),
  ADD KEY `idx_interpreter_assignments_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_interpreter_assignments_interpreter` (`company_id`,`interpreter_id`),
  ADD KEY `idx_interpreter_assignments_visitor` (`company_id`,`foreign_visitor_id`),
  ADD KEY `idx_interpreter_assignments_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_interpreter_assignments_service` (`company_id`,`service_type`,`service_reference_no`),
  ADD KEY `idx_interpreter_assignments_status` (`company_id`,`status`),
  ADD KEY `idx_interpreter_assignments_dates` (`company_id`,`start_date`,`end_date`),
  ADD KEY `idx_interpreter_assignments_currency` (`currency_code`),
  ADD KEY `idx_interpreter_assignments_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_interpreter_assignments_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `interpreter_commissions`
--
ALTER TABLE `interpreter_commissions`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_interpreter_commissions_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_interpreter_commissions_company` (`company_id`),
  ADD KEY `idx_interpreter_commissions_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_interpreter_commissions_interpreter` (`company_id`,`interpreter_id`),
  ADD KEY `idx_interpreter_commissions_service` (`company_id`,`service_type`,`service_reference_id`),
  ADD KEY `idx_interpreter_commissions_date` (`company_id`,`service_date`),
  ADD KEY `idx_interpreter_commissions_status` (`company_id`,`payment_status`),
  ADD KEY `fk_interpreter_commissions_currency` (`currency_code`),
  ADD KEY `fk_interpreter_commissions_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_interpreter_commissions_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `interpreter_documents`
--
ALTER TABLE `interpreter_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_interpreter_documents_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_interpreter_docs_company` (`company_id`),
  ADD KEY `idx_interpreter_docs_interpreter` (`company_id`,`interpreter_id`),
  ADD KEY `idx_interpreter_docs_type` (`company_id`,`document_type`),
  ADD KEY `idx_interpreter_docs_status` (`company_id`,`verification_status`),
  ADD KEY `idx_interpreter_docs_expiry` (`company_id`,`expiry_date`),
  ADD KEY `fk_interpreter_docs_verified_by_tenant` (`company_id`,`verified_by`),
  ADD KEY `fk_interpreter_docs_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_interpreter_docs_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `interpreter_id_cards`
--
ALTER TABLE `interpreter_id_cards`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_interpreter_id_cards_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_interpreter_card_no_company` (`company_id`,`card_no`),
  ADD UNIQUE KEY `uq_interpreter_verification_token` (`company_id`,`verification_token`),
  ADD KEY `idx_interpreter_cards_company` (`company_id`),
  ADD KEY `idx_interpreter_cards_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_interpreter_cards_interpreter` (`company_id`,`interpreter_id`),
  ADD KEY `idx_interpreter_cards_status` (`company_id`,`card_status`),
  ADD KEY `idx_interpreter_cards_expiry` (`company_id`,`expiry_date`),
  ADD KEY `fk_interpreter_cards_issued_by_tenant` (`company_id`,`issued_by`),
  ADD KEY `fk_interpreter_cards_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_interpreter_cards_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `invitations`
--
ALTER TABLE `invitations`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_invitations_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_invitation_no_company` (`company_id`,`invitation_no`),
  ADD KEY `idx_invitations_company_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_invitations_company_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_invitations_company_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_invitations_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_invitations_company_updated_by` (`company_id`,`updated_by`),
  ADD KEY `idx_invitations_company_status` (`company_id`,`status`),
  ADD KEY `idx_invitations_company_date` (`company_id`,`invitation_date`),
  ADD KEY `idx_invitations_company_foreign_visitor` (`company_id`,`foreign_visitor_id`),
  ADD KEY `idx_invitations_company_travel_dates` (`company_id`,`travel_start_date`,`travel_end_date`),
  ADD KEY `idx_invitations_company_permit` (`company_id`,`permit_no`),
  ADD KEY `idx_invitations_company_approval` (`company_id`,`approval_reference_no`),
  ADD KEY `idx_invitations_company_approved_by` (`company_id`,`approved_by`);

--
-- Indexes for table `invitation_documents`
--
ALTER TABLE `invitation_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_invitation_documents_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_invitation_documents_company_id_id_invitation` (`company_id`,`id`,`invitation_id`),
  ADD KEY `idx_inv_docs_company_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_inv_docs_company_type` (`company_id`,`document_type`),
  ADD KEY `idx_inv_docs_company_status` (`company_id`,`verification_status`),
  ADD KEY `idx_inv_docs_company_uploaded_by` (`company_id`,`uploaded_by`),
  ADD KEY `idx_inv_docs_company_verified_by` (`company_id`,`verified_by`),
  ADD KEY `idx_inv_docs_company_financial` (`company_id`,`financial_status`);

--
-- Indexes for table `invitation_document_financials`
--
ALTER TABLE `invitation_document_financials`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_inv_doc_fin_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_inv_doc_fin_company_document` (`company_id`,`document_id`),
  ADD KEY `idx_inv_doc_fin_company_currency` (`company_id`,`currency_code`),
  ADD KEY `idx_inv_doc_fin_company_invoice` (`company_id`,`invoice_id`),
  ADD KEY `idx_inv_doc_fin_company_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `idx_inv_doc_fin_company_status` (`company_id`,`financial_status`),
  ADD KEY `idx_inv_doc_fin_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_inv_doc_fin_company_updated_by` (`company_id`,`updated_by`),
  ADD KEY `fk_inv_doc_fin_currency` (`currency_code`),
  ADD KEY `idx_inv_doc_fin_company_invitation` (`company_id`,`invitation_id`),
  ADD KEY `fk_inv_doc_fin_document_invitation_tenant` (`company_id`,`document_id`,`invitation_id`),
  ADD KEY `fk_inv_doc_fin_invoice_invitation_tenant` (`company_id`,`invoice_id`,`invitation_id`);

--
-- Indexes for table `invitation_financials`
--
ALTER TABLE `invitation_financials`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_inv_financials_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_inv_financials_company_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_inv_fin_company_currency` (`company_id`,`currency_code`),
  ADD KEY `idx_inv_fin_company_invoice` (`company_id`,`invoice_id`),
  ADD KEY `idx_inv_fin_company_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `idx_inv_fin_company_status` (`company_id`,`financial_status`),
  ADD KEY `idx_inv_fin_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_inv_fin_company_updated_by` (`company_id`,`updated_by`),
  ADD KEY `fk_inv_fin_currency` (`currency_code`),
  ADD KEY `fk_inv_fin_invoice_invitation_tenant` (`company_id`,`invoice_id`,`invitation_id`);

--
-- Indexes for table `invitation_hotel_bookings`
--
ALTER TABLE `invitation_hotel_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_invitation_hotel_bookings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_invitation_hotel_bookings_link` (`company_id`,`invitation_id`,`hotel_booking_id`),
  ADD KEY `idx_inv_hotel_company_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_inv_hotel_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_inv_hotel_booking` (`company_id`,`hotel_booking_id`),
  ADD KEY `idx_inv_hotel_primary` (`company_id`,`invitation_id`,`is_primary`),
  ADD KEY `idx_inv_hotel_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_inv_hotel_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `invitation_transport_bookings`
--
ALTER TABLE `invitation_transport_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_invitation_transport_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_invitation_transport_link` (`company_id`,`invitation_id`,`transport_booking_id`),
  ADD KEY `idx_inv_transport_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_inv_transport_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_inv_transport_booking` (`company_id`,`transport_booking_id`),
  ADD KEY `idx_inv_transport_primary` (`company_id`,`invitation_id`,`is_primary`),
  ADD KEY `idx_inv_transport_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_inv_transport_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `invitation_visas`
--
ALTER TABLE `invitation_visas`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_invitation_visas_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_invitation_visas_link` (`company_id`,`invitation_id`,`visa_id`),
  ADD KEY `idx_invitation_visas_company_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_invitation_visas_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_invitation_visas_visa` (`company_id`,`visa_id`),
  ADD KEY `idx_invitation_visas_primary` (`company_id`,`invitation_id`,`is_primary`),
  ADD KEY `idx_invitation_visas_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_invitation_visas_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `invoices`
--
ALTER TABLE `invoices`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_invoices_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_invoice_no_company` (`company_id`,`invoice_no`),
  ADD UNIQUE KEY `uq_invoices_company_id_id_invitation` (`company_id`,`id`,`invitation_id`),
  ADD KEY `idx_invoices_company` (`company_id`),
  ADD KEY `idx_invoices_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_invoices_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_invoices_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_invoices_agency` (`company_id`,`agency_id`),
  ADD KEY `idx_invoices_invitation` (`company_id`,`invitation_id`),
  ADD KEY `idx_invoices_date` (`company_id`,`invoice_date`),
  ADD KEY `idx_invoices_due_date` (`company_id`,`due_date`),
  ADD KEY `idx_invoices_status` (`company_id`,`status`),
  ADD KEY `idx_invoices_type` (`company_id`,`invoice_type`),
  ADD KEY `idx_invoices_currency` (`currency_code`),
  ADD KEY `idx_invoices_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `idx_invoices_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_invoices_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `invoice_items`
--
ALTER TABLE `invoice_items`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ii_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_ii_invoice_line` (`company_id`,`invoice_id`,`line_no`),
  ADD KEY `idx_ii_ticket` (`company_id`,`ticket_booking_id`),
  ADD KEY `idx_ii_umrah` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_ii_hotel` (`company_id`,`hotel_booking_id`),
  ADD KEY `idx_ii_transport` (`company_id`,`transport_booking_id`),
  ADD KEY `idx_ii_visa` (`company_id`,`visa_id`),
  ADD KEY `fk_ii_service` (`service_id`),
  ADD KEY `fk_ii_discount` (`discount_id`),
  ADD KEY `fk_ii_tax` (`tax_id`);

--
-- Indexes for table `journal_entries`
--
ALTER TABLE `journal_entries`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_je_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_je_entry_no` (`company_id`,`entry_no`),
  ADD KEY `idx_je_reference` (`company_id`,`reference_type`,`reference_id`),
  ADD KEY `idx_je_date` (`company_id`,`entry_date`),
  ADD KEY `fk_je_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_je_year` (`company_id`,`fiscal_year_id`),
  ADD KEY `fk_je_period` (`company_id`,`period_id`),
  ADD KEY `fk_je_reversal` (`company_id`,`reversal_of_id`),
  ADD KEY `fk_je_currency` (`currency_code`),
  ADD KEY `fk_je_posted_by` (`company_id`,`posted_by`),
  ADD KEY `fk_je_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_je_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `journal_lines`
--
ALTER TABLE `journal_lines`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_jl_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_jl_entry_line` (`company_id`,`journal_entry_id`,`line_no`),
  ADD KEY `idx_jl_account` (`company_id`,`chart_account_id`),
  ADD KEY `idx_jl_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_jl_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_jl_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_jl_agency` (`company_id`,`agency_id`),
  ADD KEY `fk_jl_currency` (`currency_code`),
  ADD KEY `fk_jl_finance_account` (`company_id`,`finance_account_id`);

--
-- Indexes for table `languages`
--
ALTER TABLE `languages`
  ADD PRIMARY KEY (`code`);

--
-- Indexes for table `login_attempts`
--
ALTER TABLE `login_attempts`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_login_attempt_company` (`company_id`),
  ADD KEY `idx_login_attempt_username` (`company_id`,`username`),
  ADD KEY `idx_login_attempt_ip` (`ip_address`),
  ADD KEY `idx_login_attempt_time` (`attempted_at`);

--
-- Indexes for table `login_history`
--
ALTER TABLE `login_history`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_login_history_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_login_history_user` (`company_id`,`user_id`),
  ADD KEY `idx_login_history_login` (`company_id`,`login_at`);

--
-- Indexes for table `number_sequences`
--
ALTER TABLE `number_sequences`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_number_sequences_company_branch_type` (`company_id`,`branch_id`,`document_type`),
  ADD KEY `idx_number_sequences_company` (`company_id`);

--
-- Indexes for table `passports`
--
ALTER TABLE `passports`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_passports_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_passport_company_no` (`company_id`,`passport_no`),
  ADD KEY `idx_passport_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_passport_expiry` (`company_id`,`expiry_date`),
  ADD KEY `idx_passport_nationality` (`nationality_country_id`),
  ADD KEY `idx_passport_issue_country` (`issue_country_id`);

--
-- Indexes for table `password_reset_tokens`
--
ALTER TABLE `password_reset_tokens`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_password_reset_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_password_reset_token` (`token_hash`),
  ADD KEY `idx_password_reset_user` (`company_id`,`user_id`),
  ADD KEY `idx_password_reset_expiry` (`expires_at`);

--
-- Indexes for table `payments`
--
ALTER TABLE `payments`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_pay_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_pay_no` (`company_id`,`payment_no`),
  ADD KEY `idx_pay_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_pay_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_pay_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_pay_agency` (`company_id`,`agency_id`),
  ADD KEY `idx_pay_date` (`company_id`,`payment_date`),
  ADD KEY `fk_pay_branch` (`company_id`,`branch_id`),
  ADD KEY `fk_pay_account` (`company_id`,`finance_account_id`),
  ADD KEY `fk_pay_currency` (`currency_code`),
  ADD KEY `fk_pay_journal` (`company_id`,`journal_entry_id`),
  ADD KEY `fk_pay_created_by` (`company_id`,`created_by`),
  ADD KEY `fk_pay_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `payment_allocations`
--
ALTER TABLE `payment_allocations`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_pa_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_pa_payment_invoice` (`company_id`,`payment_id`,`invoice_id`),
  ADD KEY `fk_pa_invoice` (`company_id`,`invoice_id`),
  ADD KEY `fk_pa_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `permissions`
--
ALTER TABLE `permissions`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_permission_key` (`permission_key`);

--
-- Indexes for table `plans`
--
ALTER TABLE `plans`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_plan_name` (`name`);

--
-- Indexes for table `positions`
--
ALTER TABLE `positions`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_positions_company_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_positions_code` (`company_id`,`code`),
  ADD KEY `idx_positions_department` (`company_id`,`department_id`),
  ADD KEY `fk_positions_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `roles`
--
ALTER TABLE `roles`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_roles_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_role_company_name` (`company_id`,`name`),
  ADD KEY `idx_roles_company` (`company_id`);

--
-- Indexes for table `role_permissions`
--
ALTER TABLE `role_permissions`
  ADD PRIMARY KEY (`company_id`,`role_id`,`permission_id`),
  ADD KEY `idx_role_permissions_role` (`company_id`,`role_id`),
  ADD KEY `idx_role_permissions_permission` (`permission_id`);

--
-- Indexes for table `services`
--
ALTER TABLE `services`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_services_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_service_code` (`company_id`,`code`),
  ADD KEY `idx_services_company` (`company_id`),
  ADD KEY `idx_services_category` (`company_id`,`category_id`),
  ADD KEY `idx_services_type` (`company_id`,`service_type`);

--
-- Indexes for table `service_categories`
--
ALTER TABLE `service_categories`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_service_categories_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_service_category_code` (`company_id`,`code`),
  ADD KEY `idx_service_categories_company` (`company_id`);

--
-- Indexes for table `service_prices`
--
ALTER TABLE `service_prices`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_service_prices_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_service_prices_service` (`company_id`,`service_id`),
  ADD KEY `idx_service_prices_currency` (`company_id`,`currency_code`),
  ADD KEY `idx_service_prices_dates` (`company_id`,`effective_from`,`effective_to`),
  ADD KEY `fk_service_price_currency` (`currency_code`);

--
-- Indexes for table `suppliers`
--
ALTER TABLE `suppliers`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_suppliers_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_supplier_no_company` (`company_id`,`supplier_no`),
  ADD KEY `idx_suppliers_company` (`company_id`),
  ADD KEY `idx_suppliers_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_suppliers_phone` (`company_id`,`phone`),
  ADD KEY `idx_suppliers_type` (`company_id`,`supplier_type`),
  ADD KEY `idx_suppliers_city` (`city_id`),
  ADD KEY `idx_suppliers_country` (`country_id`),
  ADD KEY `fk_suppliers_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_suppliers_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `system_backups`
--
ALTER TABLE `system_backups`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_system_backups_id` (`id`),
  ADD UNIQUE KEY `uq_system_backups_no` (`company_id`,`backup_no`),
  ADD KEY `idx_system_backups_company` (`company_id`),
  ADD KEY `idx_system_backups_status` (`status`),
  ADD KEY `fk_system_backups_created_by` (`company_id`,`created_by`);

--
-- Indexes for table `system_backup_history`
--
ALTER TABLE `system_backup_history`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_sbh_company` (`company_id`),
  ADD KEY `idx_sbh_status` (`status`),
  ADD KEY `idx_sbh_started` (`started_at`),
  ADD KEY `fk_sbh_user` (`created_by`);

--
-- Indexes for table `taxes`
--
ALTER TABLE `taxes`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_taxes_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_tax_code` (`company_id`,`code`),
  ADD KEY `idx_taxes_company` (`company_id`);

--
-- Indexes for table `ticket_bookings`
--
ALTER TABLE `ticket_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ticket_bookings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_ticket_no_company` (`company_id`,`ticket_no`),
  ADD KEY `idx_ticket_booking_company` (`company_id`),
  ADD KEY `idx_ticket_booking_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_ticket_booking_booking` (`company_id`,`booking_id`),
  ADD KEY `idx_ticket_booking_passenger` (`company_id`,`passenger_id`),
  ADD KEY `idx_ticket_booking_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_ticket_booking_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_ticket_booking_source` (`company_id`,`source_id`),
  ADD KEY `idx_ticket_booking_airline` (`airline_id`),
  ADD KEY `idx_ticket_booking_pnr` (`company_id`,`pnr`),
  ADD KEY `idx_ticket_booking_departure` (`company_id`,`departure_date`),
  ADD KEY `idx_ticket_booking_status` (`company_id`,`status`),
  ADD KEY `idx_ticket_bookings_company_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_ticket_bookings_company_updated_by` (`company_id`,`updated_by`),
  ADD KEY `fk_ticket_booking_currency` (`currency_code`);

--
-- Indexes for table `ticket_documents`
--
ALTER TABLE `ticket_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ticket_documents_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_ticket_documents_ticket` (`company_id`,`ticket_id`),
  ADD KEY `idx_ticket_documents_type` (`company_id`,`document_type`),
  ADD KEY `idx_ticket_documents_uploaded` (`company_id`,`uploaded_by`),
  ADD KEY `idx_ticket_documents_verified` (`company_id`,`verified_by`);

--
-- Indexes for table `ticket_refunds`
--
ALTER TABLE `ticket_refunds`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ticket_refunds_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_refund_no_company` (`company_id`,`refund_no`),
  ADD KEY `idx_ticket_refund_ticket` (`company_id`,`ticket_id`),
  ADD KEY `idx_ticket_refund_date` (`company_id`,`refund_date`),
  ADD KEY `idx_ticket_refund_payment` (`company_id`,`payment_id`),
  ADD KEY `idx_ticket_refund_status` (`company_id`,`status`),
  ADD KEY `idx_ticket_refund_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_ticket_refund_updated_by` (`company_id`,`updated_by`),
  ADD KEY `fk_ticket_refund_currency` (`currency_code`);

--
-- Indexes for table `ticket_segments`
--
ALTER TABLE `ticket_segments`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ticket_segments_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_ticket_segment_no` (`company_id`,`ticket_id`,`segment_no`),
  ADD KEY `idx_ticket_segments_ticket` (`company_id`,`ticket_id`),
  ADD KEY `idx_ticket_segments_from` (`from_airport_id`),
  ADD KEY `idx_ticket_segments_to` (`to_airport_id`),
  ADD KEY `idx_ticket_segments_airline` (`airline_id`),
  ADD KEY `idx_ticket_segments_departure` (`company_id`,`departure_datetime`);

--
-- Indexes for table `ticket_sources`
--
ALTER TABLE `ticket_sources`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_ticket_sources_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_ticket_source_company` (`company_id`),
  ADD KEY `idx_ticket_source_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_ticket_source_agency` (`company_id`,`agency_id`),
  ADD KEY `idx_ticket_source_airline` (`airline_id`);

--
-- Indexes for table `translations`
--
ALTER TABLE `translations`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_translation_key` (`language_code`,`translation_key`);

--
-- Indexes for table `transport_bookings`
--
ALTER TABLE `transport_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_transport_bookings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_transport_no_company` (`company_id`,`transport_no`),
  ADD KEY `idx_transport_company` (`company_id`),
  ADD KEY `idx_transport_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_transport_booking` (`company_id`,`booking_id`),
  ADD KEY `idx_transport_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_transport_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_transport_vehicle` (`company_id`,`vehicle_id`),
  ADD KEY `idx_transport_driver` (`company_id`,`driver_id`),
  ADD KEY `idx_transport_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_transport_date` (`company_id`,`service_date`),
  ADD KEY `idx_transport_status` (`company_id`,`status`),
  ADD KEY `fk_transport_currency` (`currency_code`),
  ADD KEY `fk_transport_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_transport_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `umrah_bookings`
--
ALTER TABLE `umrah_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_bookings_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_umrah_no_company` (`company_id`,`umrah_no`),
  ADD KEY `idx_umrah_bookings_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_umrah_bookings_booking` (`company_id`,`booking_id`),
  ADD KEY `idx_umrah_bookings_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_umrah_bookings_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_umrah_bookings_package` (`company_id`,`package_id`),
  ADD KEY `idx_umrah_bookings_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_umrah_bookings_agency` (`company_id`,`agency_id`),
  ADD KEY `idx_umrah_bookings_source` (`company_id`,`source_type`),
  ADD KEY `idx_umrah_bookings_group` (`company_id`,`group_no`),
  ADD KEY `idx_umrah_bookings_departure` (`company_id`,`departure_date`),
  ADD KEY `idx_umrah_bookings_status` (`company_id`,`status`),
  ADD KEY `idx_umrah_bookings_currency` (`currency_code`),
  ADD KEY `idx_umrah_bookings_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_umrah_bookings_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `umrah_documents`
--
ALTER TABLE `umrah_documents`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_documents_company_id_id` (`company_id`,`id`),
  ADD KEY `idx_umrah_documents_booking` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_umrah_documents_passenger` (`company_id`,`umrah_passenger_id`),
  ADD KEY `idx_umrah_documents_type` (`company_id`,`document_type`),
  ADD KEY `idx_umrah_documents_verification` (`company_id`,`verification_status`),
  ADD KEY `idx_umrah_documents_required` (`company_id`,`is_required`,`is_received`),
  ADD KEY `idx_umrah_documents_uploaded_by` (`company_id`,`uploaded_by`),
  ADD KEY `idx_umrah_documents_verified_by` (`company_id`,`verified_by`),
  ADD KEY `fk_umrah_documents_branch_tenant` (`company_id`,`branch_id`);

--
-- Indexes for table `umrah_hotel_bookings`
--
ALTER TABLE `umrah_hotel_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_hotel_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_umrah_hotel_link` (`company_id`,`umrah_booking_id`,`hotel_booking_id`),
  ADD KEY `idx_umrah_hotel_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_umrah_hotel_umrah` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_umrah_hotel_booking` (`company_id`,`hotel_booking_id`),
  ADD KEY `idx_umrah_hotel_city` (`company_id`,`hotel_city`),
  ADD KEY `idx_umrah_hotel_primary` (`company_id`,`umrah_booking_id`,`is_primary`),
  ADD KEY `fk_umrah_hotel_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_umrah_hotel_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `umrah_packages`
--
ALTER TABLE `umrah_packages`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_packages_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_umrah_package_code_company` (`company_id`,`package_code`),
  ADD KEY `idx_umrah_packages_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_umrah_packages_status` (`company_id`,`status`),
  ADD KEY `idx_umrah_packages_makkah_hotel` (`company_id`,`makkah_hotel_id`),
  ADD KEY `idx_umrah_packages_madinah_hotel` (`company_id`,`madinah_hotel_id`),
  ADD KEY `idx_umrah_packages_currency` (`currency_code`),
  ADD KEY `idx_umrah_packages_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_umrah_packages_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `umrah_passengers`
--
ALTER TABLE `umrah_passengers`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_passengers_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_umrah_passenger_no_company` (`company_id`,`passenger_no`),
  ADD KEY `idx_umrah_passengers_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_umrah_passengers_booking` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_umrah_passengers_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_umrah_passengers_family_member` (`company_id`,`family_member_id`),
  ADD KEY `idx_umrah_passengers_passport` (`company_id`,`passport_no`),
  ADD KEY `idx_umrah_passengers_status` (`company_id`,`status`),
  ADD KEY `idx_umrah_passengers_primary` (`company_id`,`umrah_booking_id`,`is_primary`),
  ADD KEY `idx_umrah_passengers_nationality` (`nationality_country_id`),
  ADD KEY `idx_umrah_passengers_currency` (`currency_code`),
  ADD KEY `idx_umrah_passengers_created_by` (`company_id`,`created_by`),
  ADD KEY `idx_umrah_passengers_updated_by` (`company_id`,`updated_by`);

--
-- Indexes for table `umrah_ticket_bookings`
--
ALTER TABLE `umrah_ticket_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_ticket_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_umrah_ticket_link` (`company_id`,`umrah_booking_id`,`ticket_booking_id`),
  ADD KEY `idx_umrah_ticket_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_umrah_ticket_umrah` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_umrah_ticket_passenger` (`company_id`,`umrah_passenger_id`),
  ADD KEY `idx_umrah_ticket_booking` (`company_id`,`ticket_booking_id`),
  ADD KEY `idx_umrah_ticket_role` (`company_id`,`ticket_role`),
  ADD KEY `idx_umrah_ticket_primary` (`company_id`,`umrah_booking_id`,`is_primary`),
  ADD KEY `fk_umrah_ticket_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_umrah_ticket_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `umrah_transport_bookings`
--
ALTER TABLE `umrah_transport_bookings`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_umrah_transport_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_umrah_transport_link` (`company_id`,`umrah_booking_id`,`transport_booking_id`),
  ADD KEY `idx_umrah_transport_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_umrah_transport_umrah` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_umrah_transport_booking` (`company_id`,`transport_booking_id`),
  ADD KEY `idx_umrah_transport_type` (`company_id`,`transport_type`),
  ADD KEY `idx_umrah_transport_primary` (`company_id`,`umrah_booking_id`,`is_primary`),
  ADD KEY `fk_umrah_transport_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_umrah_transport_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_users_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_user_company_username` (`company_id`,`username`),
  ADD UNIQUE KEY `uq_user_company_email` (`company_id`,`email`),
  ADD KEY `idx_user_company` (`company_id`),
  ADD KEY `idx_user_company_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_user_language` (`language_code`);

--
-- Indexes for table `user_roles`
--
ALTER TABLE `user_roles`
  ADD PRIMARY KEY (`company_id`,`user_id`,`role_id`),
  ADD KEY `idx_user_roles_user` (`company_id`,`user_id`),
  ADD KEY `idx_user_roles_role` (`company_id`,`role_id`);

--
-- Indexes for table `vehicles`
--
ALTER TABLE `vehicles`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_vehicles_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_vehicle_code_company` (`company_id`,`vehicle_code`),
  ADD UNIQUE KEY `uq_vehicle_plate_company` (`company_id`,`plate_number`),
  ADD KEY `idx_vehicles_company` (`company_id`),
  ADD KEY `idx_vehicles_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_vehicles_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_vehicles_type` (`company_id`,`vehicle_type`),
  ADD KEY `idx_vehicles_status` (`company_id`,`status`),
  ADD KEY `idx_vehicles_city` (`city_id`),
  ADD KEY `idx_vehicles_country` (`country_id`),
  ADD KEY `fk_vehicles_currency` (`currency_code`),
  ADD KEY `fk_vehicles_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_vehicles_updated_by_tenant` (`company_id`,`updated_by`);

--
-- Indexes for table `visas`
--
ALTER TABLE `visas`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_visas_company_id_id` (`company_id`,`id`),
  ADD UNIQUE KEY `uq_visa_no_company` (`company_id`,`visa_no`),
  ADD KEY `idx_visas_company` (`company_id`),
  ADD KEY `idx_visas_branch` (`company_id`,`branch_id`),
  ADD KEY `idx_visas_category` (`company_id`,`visa_category`),
  ADD KEY `idx_visas_type` (`company_id`,`visa_type`),
  ADD KEY `idx_visas_visitor` (`company_id`,`foreign_visitor_id`),
  ADD KEY `idx_visas_customer` (`company_id`,`customer_id`),
  ADD KEY `idx_visas_debtor` (`company_id`,`debtor_id`),
  ADD KEY `idx_visas_umrah_booking` (`company_id`,`umrah_booking_id`),
  ADD KEY `idx_visas_umrah_passenger` (`company_id`,`umrah_passenger_id`),
  ADD KEY `idx_visas_supplier` (`company_id`,`supplier_id`),
  ADD KEY `idx_visas_agency` (`company_id`,`agency_id`),
  ADD KEY `idx_visas_destination` (`destination_country_id`),
  ADD KEY `idx_visas_status` (`company_id`,`status`),
  ADD KEY `idx_visas_expiry` (`company_id`,`expiry_date`),
  ADD KEY `fk_visas_issuing_country` (`issuing_country_id`),
  ADD KEY `fk_visas_currency` (`currency_code`),
  ADD KEY `fk_visas_created_by_tenant` (`company_id`,`created_by`),
  ADD KEY `fk_visas_updated_by_tenant` (`company_id`,`updated_by`);

--
--
  ADD PRIMARY KEY (`id`),

--
--
  ADD PRIMARY KEY (`id`),

--
--
  ADD PRIMARY KEY (`id`),

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `account_mappings`
--
ALTER TABLE `account_mappings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `agencies`
--
ALTER TABLE `agencies`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `airlines`
--
ALTER TABLE `airlines`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `airports`
--
ALTER TABLE `airports`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `audit_logs`
--
ALTER TABLE `audit_logs`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `backup_restore_history`
--
ALTER TABLE `backup_restore_history`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `bookings`
--
ALTER TABLE `bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `booking_passengers`
--
ALTER TABLE `booking_passengers`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `branches`
--
ALTER TABLE `branches`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `cities`
--
ALTER TABLE `cities`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `companies`
--
ALTER TABLE `companies`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `company_branding`
--
ALTER TABLE `company_branding`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `company_settings`
--
ALTER TABLE `company_settings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `countries`
--
ALTER TABLE `countries`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `customers`
--
ALTER TABLE `customers`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `customer_addresses`
--
ALTER TABLE `customer_addresses`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `customer_documents`
--
ALTER TABLE `customer_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `debtors`
--
ALTER TABLE `debtors`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `debtor_addresses`
--
ALTER TABLE `debtor_addresses`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `debtor_guarantors`
--
ALTER TABLE `debtor_guarantors`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `departments`
--
ALTER TABLE `departments`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `discounts`
--
ALTER TABLE `discounts`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `drivers`
--
ALTER TABLE `drivers`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employees`
--
ALTER TABLE `employees`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employee_attendance`
--
ALTER TABLE `employee_attendance`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employee_contracts`
--
ALTER TABLE `employee_contracts`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employee_documents`
--
ALTER TABLE `employee_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employee_leaves`
--
ALTER TABLE `employee_leaves`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employee_salary_payments`
--
ALTER TABLE `employee_salary_payments`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `employee_user_accounts`
--
ALTER TABLE `employee_user_accounts`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `exchange_rates`
--
ALTER TABLE `exchange_rates`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `expenses`
--
ALTER TABLE `expenses`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `family_members`
--
ALTER TABLE `family_members`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `finance_accounts`
--
ALTER TABLE `finance_accounts`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=36;

--
-- AUTO_INCREMENT for table `finance_agency_ledger`
--
ALTER TABLE `finance_agency_ledger`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `finance_approvals`
--
ALTER TABLE `finance_approvals`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `finance_audit_log`
--
ALTER TABLE `finance_audit_log`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `finance_chart_accounts`
--
ALTER TABLE `finance_chart_accounts`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=84;

--
-- AUTO_INCREMENT for table `finance_customer_ledger`
--
ALTER TABLE `finance_customer_ledger`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `finance_fiscal_years`
--
ALTER TABLE `finance_fiscal_years`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `finance_periods`
--
ALTER TABLE `finance_periods`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=14;

--
-- AUTO_INCREMENT for table `finance_profit_records`
--
ALTER TABLE `finance_profit_records`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `finance_refunds`
--
ALTER TABLE `finance_refunds`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `finance_service_costs`
--
ALTER TABLE `finance_service_costs`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `finance_supplier_ledger`
--
ALTER TABLE `finance_supplier_ledger`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `finance_transaction_links`
--
ALTER TABLE `finance_transaction_links`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `foreign_visitors`
--
ALTER TABLE `foreign_visitors`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `foreign_visitor_documents`
--
ALTER TABLE `foreign_visitor_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `hotels`
--
ALTER TABLE `hotels`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `hotel_bookings`
--
ALTER TABLE `hotel_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `hotel_room_types`
--
ALTER TABLE `hotel_room_types`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `interpreters`
--
ALTER TABLE `interpreters`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `interpreter_assignments`
--
ALTER TABLE `interpreter_assignments`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `interpreter_commissions`
--
ALTER TABLE `interpreter_commissions`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `interpreter_documents`
--
ALTER TABLE `interpreter_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `interpreter_id_cards`
--
ALTER TABLE `interpreter_id_cards`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitations`
--
ALTER TABLE `invitations`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitation_documents`
--
ALTER TABLE `invitation_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitation_document_financials`
--
ALTER TABLE `invitation_document_financials`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitation_financials`
--
ALTER TABLE `invitation_financials`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitation_hotel_bookings`
--
ALTER TABLE `invitation_hotel_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitation_transport_bookings`
--
ALTER TABLE `invitation_transport_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invitation_visas`
--
ALTER TABLE `invitation_visas`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `invoices`
--
ALTER TABLE `invoices`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `invoice_items`
--
ALTER TABLE `invoice_items`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `journal_entries`
--
ALTER TABLE `journal_entries`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=4;

--
-- AUTO_INCREMENT for table `journal_lines`
--
ALTER TABLE `journal_lines`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=9;

--
-- AUTO_INCREMENT for table `login_attempts`
--
ALTER TABLE `login_attempts`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `login_history`
--
ALTER TABLE `login_history`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `number_sequences`
--
ALTER TABLE `number_sequences`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=18;

--
-- AUTO_INCREMENT for table `passports`
--
ALTER TABLE `passports`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `password_reset_tokens`
--
ALTER TABLE `password_reset_tokens`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `payments`
--
ALTER TABLE `payments`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `payment_allocations`
--
ALTER TABLE `payment_allocations`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `permissions`
--
ALTER TABLE `permissions`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `plans`
--
ALTER TABLE `plans`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `positions`
--
ALTER TABLE `positions`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `roles`
--
ALTER TABLE `roles`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `services`
--
ALTER TABLE `services`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `service_categories`
--
ALTER TABLE `service_categories`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `service_prices`
--
ALTER TABLE `service_prices`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `suppliers`
--
ALTER TABLE `suppliers`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `system_backups`
--
ALTER TABLE `system_backups`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `system_backup_history`
--
ALTER TABLE `system_backup_history`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `taxes`
--
ALTER TABLE `taxes`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ticket_bookings`
--
ALTER TABLE `ticket_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `ticket_documents`
--
ALTER TABLE `ticket_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ticket_refunds`
--
ALTER TABLE `ticket_refunds`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ticket_segments`
--
ALTER TABLE `ticket_segments`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `ticket_sources`
--
ALTER TABLE `ticket_sources`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `translations`
--
ALTER TABLE `translations`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `transport_bookings`
--
ALTER TABLE `transport_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_bookings`
--
ALTER TABLE `umrah_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_documents`
--
ALTER TABLE `umrah_documents`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_hotel_bookings`
--
ALTER TABLE `umrah_hotel_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_packages`
--
ALTER TABLE `umrah_packages`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_passengers`
--
ALTER TABLE `umrah_passengers`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_ticket_bookings`
--
ALTER TABLE `umrah_ticket_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `umrah_transport_bookings`
--
ALTER TABLE `umrah_transport_bookings`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `users`
--
ALTER TABLE `users`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `vehicles`
--
ALTER TABLE `vehicles`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `visas`
--
ALTER TABLE `visas`
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
--
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
--
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
--
  MODIFY `id` bigint(20) UNSIGNED NOT NULL AUTO_INCREMENT;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `account_mappings`
--
ALTER TABLE `account_mappings`
  ADD CONSTRAINT `fk_account_mappings_account_tenant` FOREIGN KEY (`company_id`,`account_id`) REFERENCES `finance_chart_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_account_mappings_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_account_mappings_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_account_mappings_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `agencies`
--
ALTER TABLE `agencies`
  ADD CONSTRAINT `fk_agencies_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_agencies_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_agency_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_agency_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_agency_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_agency_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`);

--
-- Constraints for table `airports`
--
ALTER TABLE `airports`
  ADD CONSTRAINT `fk_airport_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_airport_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`);

--
-- Constraints for table `audit_logs`
--
ALTER TABLE `audit_logs`
  ADD CONSTRAINT `fk_audit_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_audit_user_tenant` FOREIGN KEY (`company_id`,`user_id`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `backup_restore_history`
--
ALTER TABLE `backup_restore_history`
  ADD CONSTRAINT `fk_backup_restore_backup` FOREIGN KEY (`backup_id`) REFERENCES `system_backups` (`id`),
  ADD CONSTRAINT `fk_backup_restore_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_backup_restore_user` FOREIGN KEY (`company_id`,`performed_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `bookings`
--
ALTER TABLE `bookings`
  ADD CONSTRAINT `fk_booking_agency_tenant` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_booking_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_booking_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_booking_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_booking_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_bookings_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_bookings_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `booking_passengers`
--
ALTER TABLE `booking_passengers`
  ADD CONSTRAINT `fk_booking_passenger_booking_tenant` FOREIGN KEY (`company_id`,`booking_id`) REFERENCES `bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_booking_passenger_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_booking_passenger_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_booking_passenger_nationality` FOREIGN KEY (`nationality_country_id`) REFERENCES `countries` (`id`);

--
-- Constraints for table `branches`
--
ALTER TABLE `branches`
  ADD CONSTRAINT `fk_branch_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_branch_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_branch_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_branch_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`);

--
-- Constraints for table `cities`
--
ALTER TABLE `cities`
  ADD CONSTRAINT `fk_city_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`);

--
-- Constraints for table `companies`
--
ALTER TABLE `companies`
  ADD CONSTRAINT `fk_company_default_currency` FOREIGN KEY (`default_currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_company_default_language` FOREIGN KEY (`default_language_code`) REFERENCES `languages` (`code`);

--
-- Constraints for table `company_branding`
--
ALTER TABLE `company_branding`
  ADD CONSTRAINT `fk_company_branding_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `company_currencies`
--
ALTER TABLE `company_currencies`
  ADD CONSTRAINT `fk_cc_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_cc_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`);

--
-- Constraints for table `company_settings`
--
ALTER TABLE `company_settings`
  ADD CONSTRAINT `fk_company_settings_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `customers`
--
ALTER TABLE `customers`
  ADD CONSTRAINT `fk_customer_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_customer_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_customer_nationality` FOREIGN KEY (`nationality_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_customers_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_customers_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `customer_addresses`
--
ALTER TABLE `customer_addresses`
  ADD CONSTRAINT `fk_customer_address_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_customer_address_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_customer_address_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_customer_address_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`);

--
-- Constraints for table `customer_documents`
--
ALTER TABLE `customer_documents`
  ADD CONSTRAINT `fk_customer_document_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_customer_document_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_customer_document_uploaded_by_tenant` FOREIGN KEY (`company_id`,`uploaded_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_customer_document_verified_by_tenant` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `debtors`
--
ALTER TABLE `debtors`
  ADD CONSTRAINT `fk_debtor_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_debtor_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_debtors_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `debtor_addresses`
--
ALTER TABLE `debtor_addresses`
  ADD CONSTRAINT `fk_debtor_address_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_debtor_address_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_debtor_address_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_debtor_address_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`);

--
-- Constraints for table `debtor_guarantors`
--
ALTER TABLE `debtor_guarantors`
  ADD CONSTRAINT `fk_debtor_guarantor_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_debtor_guarantor_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`);

--
-- Constraints for table `departments`
--
ALTER TABLE `departments`
  ADD CONSTRAINT `fk_departments_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_departments_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_departments_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_departments_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `discounts`
--
ALTER TABLE `discounts`
  ADD CONSTRAINT `fk_discount_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `drivers`
--
ALTER TABLE `drivers`
  ADD CONSTRAINT `fk_drivers_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_drivers_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_drivers_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_drivers_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_drivers_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_drivers_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `employees`
--
ALTER TABLE `employees`
  ADD CONSTRAINT `fk_employees_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employees_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_employees_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employees_currency` FOREIGN KEY (`salary_currency`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_employees_department` FOREIGN KEY (`company_id`,`department_id`) REFERENCES `departments` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employees_manager` FOREIGN KEY (`company_id`,`manager_id`) REFERENCES `employees` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employees_position` FOREIGN KEY (`company_id`,`position_id`) REFERENCES `positions` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employees_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `employee_attendance`
--
ALTER TABLE `employee_attendance`
  ADD CONSTRAINT `fk_employee_attendance_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_attendance_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_employee_attendance_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_attendance_employee` FOREIGN KEY (`company_id`,`employee_id`) REFERENCES `employees` (`company_id`, `id`);

--
-- Constraints for table `employee_contracts`
--
ALTER TABLE `employee_contracts`
  ADD CONSTRAINT `fk_employee_contract_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_employee_contract_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_contract_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_employee_contract_employee` FOREIGN KEY (`company_id`,`employee_id`) REFERENCES `employees` (`company_id`, `id`);

--
-- Constraints for table `employee_documents`
--
ALTER TABLE `employee_documents`
  ADD CONSTRAINT `fk_employee_documents_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_employee_documents_employee` FOREIGN KEY (`company_id`,`employee_id`) REFERENCES `employees` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_documents_uploaded_by` FOREIGN KEY (`company_id`,`uploaded_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_documents_verified_by` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `employee_leaves`
--
ALTER TABLE `employee_leaves`
  ADD CONSTRAINT `fk_employee_leaves_approved_by` FOREIGN KEY (`company_id`,`approved_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_leaves_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_employee_leaves_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_leaves_employee` FOREIGN KEY (`company_id`,`employee_id`) REFERENCES `employees` (`company_id`, `id`);

--
-- Constraints for table `employee_salary_payments`
--
ALTER TABLE `employee_salary_payments`
  ADD CONSTRAINT `fk_salary_approved_by` FOREIGN KEY (`company_id`,`approved_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_salary_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_salary_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_salary_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_salary_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_salary_employee` FOREIGN KEY (`company_id`,`employee_id`) REFERENCES `employees` (`company_id`, `id`),
  ADD CONSTRAINT `fk_salary_finance_account` FOREIGN KEY (`company_id`,`finance_account_id`) REFERENCES `finance_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_salary_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`);

--
-- Constraints for table `employee_user_accounts`
--
ALTER TABLE `employee_user_accounts`
  ADD CONSTRAINT `fk_employee_user_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_employee_user_employee` FOREIGN KEY (`company_id`,`employee_id`) REFERENCES `employees` (`company_id`, `id`),
  ADD CONSTRAINT `fk_employee_user_user` FOREIGN KEY (`company_id`,`user_id`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `exchange_rates`
--
ALTER TABLE `exchange_rates`
  ADD CONSTRAINT `fk_exchange_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_exchange_from_currency` FOREIGN KEY (`from_currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_exchange_to_currency` FOREIGN KEY (`to_currency_code`) REFERENCES `currencies` (`code`);

--
-- Constraints for table `expenses`
--
ALTER TABLE `expenses`
  ADD CONSTRAINT `fk_exp_account` FOREIGN KEY (`company_id`,`expense_account_id`) REFERENCES `finance_chart_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_exp_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_exp_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_exp_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_exp_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_exp_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_exp_payment_account` FOREIGN KEY (`company_id`,`payment_account_id`) REFERENCES `finance_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_exp_supplier` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_exp_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `family_members`
--
ALTER TABLE `family_members`
  ADD CONSTRAINT `fk_family_member_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_family_member_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`);

--
-- Constraints for table `finance_accounts`
--
ALTER TABLE `finance_accounts`
  ADD CONSTRAINT `fk_fa_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fa_chart` FOREIGN KEY (`company_id`,`chart_account_id`) REFERENCES `finance_chart_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fa_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fa_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fa_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fa_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `finance_agency_ledger`
--
ALTER TABLE `finance_agency_ledger`
  ADD CONSTRAINT `fk_fal_agency` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fal_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fal_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fal_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fal_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fal_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fal_payment` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`);

--
-- Constraints for table `finance_approvals`
--
ALTER TABLE `finance_approvals`
  ADD CONSTRAINT `fk_fap_approved_by` FOREIGN KEY (`company_id`,`approved_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fap_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fap_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fap_requested_by` FOREIGN KEY (`company_id`,`requested_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `finance_audit_log`
--
ALTER TABLE `finance_audit_log`
  ADD CONSTRAINT `fk_fal_audit_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fal_audit_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fal_audit_user` FOREIGN KEY (`company_id`,`user_id`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `finance_chart_accounts`
--
ALTER TABLE `finance_chart_accounts`
  ADD CONSTRAINT `fk_fca_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fca_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fca_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fca_parent` FOREIGN KEY (`company_id`,`parent_account_id`) REFERENCES `finance_chart_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fca_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `finance_customer_ledger`
--
ALTER TABLE `finance_customer_ledger`
  ADD CONSTRAINT `fk_fcl_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fcl_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fcl_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fcl_customer` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fcl_debtor` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fcl_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fcl_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fcl_payment` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`);

--
-- Constraints for table `finance_fiscal_years`
--
ALTER TABLE `finance_fiscal_years`
  ADD CONSTRAINT `fk_fy_closed_by` FOREIGN KEY (`company_id`,`closed_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fy_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fy_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fy_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `finance_periods`
--
ALTER TABLE `finance_periods`
  ADD CONSTRAINT `fk_fp_closed_by` FOREIGN KEY (`company_id`,`closed_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fp_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fp_year` FOREIGN KEY (`company_id`,`fiscal_year_id`) REFERENCES `finance_fiscal_years` (`company_id`, `id`);

--
-- Constraints for table `finance_profit_records`
--
ALTER TABLE `finance_profit_records`
  ADD CONSTRAINT `fk_fpr_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fpr_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fpr_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fpr_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fpr_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`);

--
-- Constraints for table `finance_refunds`
--
ALTER TABLE `finance_refunds`
  ADD CONSTRAINT `fk_fr_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fr_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fr_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fr_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fr_customer` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fr_debtor` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fr_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fr_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fr_payment` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`);

--
-- Constraints for table `finance_service_costs`
--
ALTER TABLE `finance_service_costs`
  ADD CONSTRAINT `fk_fsc_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsc_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fsc_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsc_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fsc_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsc_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsc_supplier` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`);

--
-- Constraints for table `finance_supplier_ledger`
--
ALTER TABLE `finance_supplier_ledger`
  ADD CONSTRAINT `fk_fsl_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsl_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fsl_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_fsl_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsl_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsl_payment` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fsl_supplier` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`);

--
-- Constraints for table `finance_transaction_links`
--
ALTER TABLE `finance_transaction_links`
  ADD CONSTRAINT `fk_ftl_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ftl_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ftl_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ftl_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ftl_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ftl_payment` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`);

--
-- Constraints for table `foreign_visitors`
--
ALTER TABLE `foreign_visitors`
  ADD CONSTRAINT `fk_foreign_visitors_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_foreign_visitors_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_foreign_visitors_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_foreign_visitors_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_foreign_visitors_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_foreign_visitors_nationality` FOREIGN KEY (`nationality_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_foreign_visitors_passport_country` FOREIGN KEY (`passport_issue_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_foreign_visitors_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `foreign_visitor_documents`
--
ALTER TABLE `foreign_visitor_documents`
  ADD CONSTRAINT `fk_fvd_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_fvd_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fvd_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fvd_verified_by_tenant` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_fvd_visitor_tenant` FOREIGN KEY (`company_id`,`visitor_id`) REFERENCES `foreign_visitors` (`company_id`, `id`);

--
-- Constraints for table `hotels`
--
ALTER TABLE `hotels`
  ADD CONSTRAINT `fk_hotels_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotels_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_hotels_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_hotels_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_hotels_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotels_supplier_tenant` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotels_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `hotel_bookings`
--
ALTER TABLE `hotel_bookings`
  ADD CONSTRAINT `fk_hotel_booking_booking_tenant` FOREIGN KEY (`company_id`,`booking_id`) REFERENCES `bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_hotel_booking_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_hotel_booking_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_hotel_tenant` FOREIGN KEY (`company_id`,`hotel_id`) REFERENCES `hotels` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_room_tenant` FOREIGN KEY (`company_id`,`room_type_id`) REFERENCES `hotel_room_types` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_booking_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `hotel_room_types`
--
ALTER TABLE `hotel_room_types`
  ADD CONSTRAINT `fk_hotel_room_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_hotel_room_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_room_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_hotel_room_hotel_tenant` FOREIGN KEY (`company_id`,`hotel_id`) REFERENCES `hotels` (`company_id`, `id`),
  ADD CONSTRAINT `fk_hotel_room_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `interpreters`
--
ALTER TABLE `interpreters`
  ADD CONSTRAINT `fk_interpreters_approved_by_tenant` FOREIGN KEY (`company_id`,`approved_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreters_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreters_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_interpreters_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_interpreters_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_interpreters_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreters_nationality` FOREIGN KEY (`nationality_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_interpreters_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `interpreter_assignments`
--
ALTER TABLE `interpreter_assignments`
  ADD CONSTRAINT `fk_interpreter_assignments_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_assignments_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_interpreter_assignments_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_assignments_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_interpreter_assignments_interpreter_tenant` FOREIGN KEY (`company_id`,`interpreter_id`) REFERENCES `interpreters` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_assignments_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_assignments_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_assignments_visitor_tenant` FOREIGN KEY (`company_id`,`foreign_visitor_id`) REFERENCES `foreign_visitors` (`company_id`, `id`);

--
-- Constraints for table `interpreter_commissions`
--
ALTER TABLE `interpreter_commissions`
  ADD CONSTRAINT `fk_interpreter_commissions_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_commissions_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_interpreter_commissions_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_commissions_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_interpreter_commissions_interpreter_tenant` FOREIGN KEY (`company_id`,`interpreter_id`) REFERENCES `interpreters` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_commissions_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `interpreter_documents`
--
ALTER TABLE `interpreter_documents`
  ADD CONSTRAINT `fk_interpreter_docs_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_interpreter_docs_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_docs_interpreter_tenant` FOREIGN KEY (`company_id`,`interpreter_id`) REFERENCES `interpreters` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_docs_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_docs_verified_by_tenant` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `interpreter_id_cards`
--
ALTER TABLE `interpreter_id_cards`
  ADD CONSTRAINT `fk_interpreter_cards_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_cards_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_interpreter_cards_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_cards_interpreter_tenant` FOREIGN KEY (`company_id`,`interpreter_id`) REFERENCES `interpreters` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_cards_issued_by_tenant` FOREIGN KEY (`company_id`,`issued_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_interpreter_cards_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitations`
--
ALTER TABLE `invitations`
  ADD CONSTRAINT `fk_invitations_approved_by_tenant` FOREIGN KEY (`company_id`,`approved_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitations_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitations_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_invitations_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitations_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitations_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitations_foreign_visitor_tenant` FOREIGN KEY (`company_id`,`foreign_visitor_id`) REFERENCES `foreign_visitors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitations_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitation_documents`
--
ALTER TABLE `invitation_documents`
  ADD CONSTRAINT `fk_inv_docs_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_inv_docs_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`) ON DELETE CASCADE,
  ADD CONSTRAINT `fk_inv_docs_uploaded_by_tenant` FOREIGN KEY (`company_id`,`uploaded_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_docs_verified_by_tenant` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitation_document_financials`
--
ALTER TABLE `invitation_document_financials`
  ADD CONSTRAINT `fk_inv_doc_fin_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_inv_doc_fin_company_currency` FOREIGN KEY (`company_id`,`currency_code`) REFERENCES `company_currencies` (`company_id`, `currency_code`),
  ADD CONSTRAINT `fk_inv_doc_fin_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_doc_fin_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_inv_doc_fin_document_invitation_tenant` FOREIGN KEY (`company_id`,`document_id`,`invitation_id`) REFERENCES `invitation_documents` (`company_id`, `id`, `invitation_id`),
  ADD CONSTRAINT `fk_inv_doc_fin_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_doc_fin_invoice_invitation_tenant` FOREIGN KEY (`company_id`,`invoice_id`,`invitation_id`) REFERENCES `invoices` (`company_id`, `id`, `invitation_id`),
  ADD CONSTRAINT `fk_inv_doc_fin_journal_tenant` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_doc_fin_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitation_financials`
--
ALTER TABLE `invitation_financials`
  ADD CONSTRAINT `fk_inv_fin_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_inv_fin_company_currency` FOREIGN KEY (`company_id`,`currency_code`) REFERENCES `company_currencies` (`company_id`, `currency_code`),
  ADD CONSTRAINT `fk_inv_fin_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_fin_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_inv_fin_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_fin_invoice_invitation_tenant` FOREIGN KEY (`company_id`,`invoice_id`,`invitation_id`) REFERENCES `invoices` (`company_id`, `id`, `invitation_id`),
  ADD CONSTRAINT `fk_inv_fin_journal_tenant` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_fin_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitation_hotel_bookings`
--
ALTER TABLE `invitation_hotel_bookings`
  ADD CONSTRAINT `fk_inv_hotel_booking_tenant` FOREIGN KEY (`company_id`,`hotel_booking_id`) REFERENCES `hotel_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_hotel_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_hotel_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_inv_hotel_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_hotel_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_hotel_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitation_transport_bookings`
--
ALTER TABLE `invitation_transport_bookings`
  ADD CONSTRAINT `fk_inv_transport_booking_tenant` FOREIGN KEY (`company_id`,`transport_booking_id`) REFERENCES `transport_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_transport_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_transport_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_inv_transport_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_transport_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_inv_transport_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invitation_visas`
--
ALTER TABLE `invitation_visas`
  ADD CONSTRAINT `fk_invitation_visas_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitation_visas_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_invitation_visas_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitation_visas_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitation_visas_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invitation_visas_visa_tenant` FOREIGN KEY (`company_id`,`visa_id`) REFERENCES `visas` (`company_id`, `id`);

--
-- Constraints for table `invoices`
--
ALTER TABLE `invoices`
  ADD CONSTRAINT `fk_invoices_agency_tenant` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_invoices_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_invoices_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_invitation_tenant` FOREIGN KEY (`company_id`,`invitation_id`) REFERENCES `invitations` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_journal_tenant` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_invoices_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `invoice_items`
--
ALTER TABLE `invoice_items`
  ADD CONSTRAINT `fk_ii_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ii_discount` FOREIGN KEY (`discount_id`) REFERENCES `discounts` (`id`),
  ADD CONSTRAINT `fk_ii_hotel` FOREIGN KEY (`company_id`,`hotel_booking_id`) REFERENCES `hotel_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ii_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ii_service` FOREIGN KEY (`service_id`) REFERENCES `services` (`id`),
  ADD CONSTRAINT `fk_ii_tax` FOREIGN KEY (`tax_id`) REFERENCES `taxes` (`id`),
  ADD CONSTRAINT `fk_ii_ticket` FOREIGN KEY (`company_id`,`ticket_booking_id`) REFERENCES `ticket_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ii_transport` FOREIGN KEY (`company_id`,`transport_booking_id`) REFERENCES `transport_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ii_umrah` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ii_visa` FOREIGN KEY (`company_id`,`visa_id`) REFERENCES `visas` (`company_id`, `id`);

--
-- Constraints for table `journal_entries`
--
ALTER TABLE `journal_entries`
  ADD CONSTRAINT `fk_je_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_je_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_je_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_je_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_je_period` FOREIGN KEY (`company_id`,`period_id`) REFERENCES `finance_periods` (`company_id`, `id`),
  ADD CONSTRAINT `fk_je_posted_by` FOREIGN KEY (`company_id`,`posted_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_je_reversal` FOREIGN KEY (`company_id`,`reversal_of_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_je_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_je_year` FOREIGN KEY (`company_id`,`fiscal_year_id`) REFERENCES `finance_fiscal_years` (`company_id`, `id`);

--
-- Constraints for table `journal_lines`
--
ALTER TABLE `journal_lines`
  ADD CONSTRAINT `fk_jl_account` FOREIGN KEY (`company_id`,`chart_account_id`) REFERENCES `finance_chart_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_jl_agency` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_jl_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_jl_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_jl_customer` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_jl_debtor` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_jl_entry` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_jl_finance_account` FOREIGN KEY (`company_id`,`finance_account_id`) REFERENCES `finance_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_jl_supplier` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`);

--
-- Constraints for table `login_attempts`
--
ALTER TABLE `login_attempts`
  ADD CONSTRAINT `fk_login_attempt_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `login_history`
--
ALTER TABLE `login_history`
  ADD CONSTRAINT `fk_login_history_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_login_history_user_tenant` FOREIGN KEY (`company_id`,`user_id`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `number_sequences`
--
ALTER TABLE `number_sequences`
  ADD CONSTRAINT `fk_number_sequences_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `passports`
--
ALTER TABLE `passports`
  ADD CONSTRAINT `fk_passport_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_passport_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_passport_issue_country` FOREIGN KEY (`issue_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_passport_nationality` FOREIGN KEY (`nationality_country_id`) REFERENCES `countries` (`id`);

--
-- Constraints for table `password_reset_tokens`
--
ALTER TABLE `password_reset_tokens`
  ADD CONSTRAINT `fk_prt_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_prt_user_tenant` FOREIGN KEY (`company_id`,`user_id`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `payments`
--
ALTER TABLE `payments`
  ADD CONSTRAINT `fk_pay_account` FOREIGN KEY (`company_id`,`finance_account_id`) REFERENCES `finance_accounts` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_agency` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_branch` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_pay_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_pay_customer` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_debtor` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_journal` FOREIGN KEY (`company_id`,`journal_entry_id`) REFERENCES `journal_entries` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_supplier` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pay_updated_by` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `payment_allocations`
--
ALTER TABLE `payment_allocations`
  ADD CONSTRAINT `fk_pa_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_pa_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pa_invoice` FOREIGN KEY (`company_id`,`invoice_id`) REFERENCES `invoices` (`company_id`, `id`),
  ADD CONSTRAINT `fk_pa_payment` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`);

--
-- Constraints for table `positions`
--
ALTER TABLE `positions`
  ADD CONSTRAINT `fk_positions_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_positions_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_positions_department` FOREIGN KEY (`company_id`,`department_id`) REFERENCES `departments` (`company_id`, `id`);

--
-- Constraints for table `roles`
--
ALTER TABLE `roles`
  ADD CONSTRAINT `fk_role_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `role_permissions`
--
ALTER TABLE `role_permissions`
  ADD CONSTRAINT `fk_rp_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_rp_permission` FOREIGN KEY (`permission_id`) REFERENCES `permissions` (`id`),
  ADD CONSTRAINT `fk_rp_role_tenant` FOREIGN KEY (`company_id`,`role_id`) REFERENCES `roles` (`company_id`, `id`);

--
-- Constraints for table `services`
--
ALTER TABLE `services`
  ADD CONSTRAINT `fk_service_category_tenant` FOREIGN KEY (`company_id`,`category_id`) REFERENCES `service_categories` (`company_id`, `id`),
  ADD CONSTRAINT `fk_service_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `service_categories`
--
ALTER TABLE `service_categories`
  ADD CONSTRAINT `fk_service_category_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `service_prices`
--
ALTER TABLE `service_prices`
  ADD CONSTRAINT `fk_service_price_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_service_price_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_service_price_service_tenant` FOREIGN KEY (`company_id`,`service_id`) REFERENCES `services` (`company_id`, `id`);

--
-- Constraints for table `suppliers`
--
ALTER TABLE `suppliers`
  ADD CONSTRAINT `fk_supplier_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_supplier_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_supplier_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_supplier_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_suppliers_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_suppliers_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `system_backups`
--
ALTER TABLE `system_backups`
  ADD CONSTRAINT `fk_system_backups_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_system_backups_created_by` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `system_backup_history`
--
ALTER TABLE `system_backup_history`
  ADD CONSTRAINT `fk_sbh_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_sbh_user` FOREIGN KEY (`created_by`) REFERENCES `users` (`id`);

--
-- Constraints for table `taxes`
--
ALTER TABLE `taxes`
  ADD CONSTRAINT `fk_tax_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`);

--
-- Constraints for table `ticket_bookings`
--
ALTER TABLE `ticket_bookings`
  ADD CONSTRAINT `fk_ticket_booking_airline` FOREIGN KEY (`airline_id`) REFERENCES `airlines` (`id`),
  ADD CONSTRAINT `fk_ticket_booking_booking_tenant` FOREIGN KEY (`company_id`,`booking_id`) REFERENCES `bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_booking_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_booking_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ticket_booking_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_ticket_booking_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_booking_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_booking_passenger_tenant` FOREIGN KEY (`company_id`,`passenger_id`) REFERENCES `booking_passengers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_booking_source_tenant` FOREIGN KEY (`company_id`,`source_id`) REFERENCES `ticket_sources` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_bookings_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_bookings_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `ticket_documents`
--
ALTER TABLE `ticket_documents`
  ADD CONSTRAINT `fk_ticket_document_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ticket_document_ticket_tenant` FOREIGN KEY (`company_id`,`ticket_id`) REFERENCES `ticket_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_document_uploaded_by_tenant` FOREIGN KEY (`company_id`,`uploaded_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_document_verified_by_tenant` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `ticket_refunds`
--
ALTER TABLE `ticket_refunds`
  ADD CONSTRAINT `fk_ticket_refund_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ticket_refund_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_ticket_refund_payment_tenant` FOREIGN KEY (`company_id`,`payment_id`) REFERENCES `payments` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_refund_ticket_tenant` FOREIGN KEY (`company_id`,`ticket_id`) REFERENCES `ticket_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_refunds_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_refunds_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `ticket_segments`
--
ALTER TABLE `ticket_segments`
  ADD CONSTRAINT `fk_ticket_segment_airline` FOREIGN KEY (`airline_id`) REFERENCES `airlines` (`id`),
  ADD CONSTRAINT `fk_ticket_segment_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ticket_segment_from_airport` FOREIGN KEY (`from_airport_id`) REFERENCES `airports` (`id`),
  ADD CONSTRAINT `fk_ticket_segment_ticket_tenant` FOREIGN KEY (`company_id`,`ticket_id`) REFERENCES `ticket_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_segment_to_airport` FOREIGN KEY (`to_airport_id`) REFERENCES `airports` (`id`);

--
-- Constraints for table `ticket_sources`
--
ALTER TABLE `ticket_sources`
  ADD CONSTRAINT `fk_ticket_source_agency_tenant` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ticket_source_airline` FOREIGN KEY (`airline_id`) REFERENCES `airlines` (`id`),
  ADD CONSTRAINT `fk_ticket_source_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ticket_source_supplier_tenant` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`);

--
-- Constraints for table `translations`
--
ALTER TABLE `translations`
  ADD CONSTRAINT `fk_translation_language` FOREIGN KEY (`language_code`) REFERENCES `languages` (`code`);

--
-- Constraints for table `transport_bookings`
--
ALTER TABLE `transport_bookings`
  ADD CONSTRAINT `fk_transport_booking_tenant` FOREIGN KEY (`company_id`,`booking_id`) REFERENCES `bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_transport_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_transport_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_driver_tenant` FOREIGN KEY (`company_id`,`driver_id`) REFERENCES `drivers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_supplier_tenant` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_transport_vehicle_tenant` FOREIGN KEY (`company_id`,`vehicle_id`) REFERENCES `vehicles` (`company_id`, `id`);

--
-- Constraints for table `umrah_bookings`
--
ALTER TABLE `umrah_bookings`
  ADD CONSTRAINT `fk_umrah_bookings_agency_tenant` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_booking_tenant` FOREIGN KEY (`company_id`,`booking_id`) REFERENCES `bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_bookings_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_umrah_bookings_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_package_tenant` FOREIGN KEY (`company_id`,`package_id`) REFERENCES `umrah_packages` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_supplier_tenant` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_bookings_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `umrah_documents`
--
ALTER TABLE `umrah_documents`
  ADD CONSTRAINT `fk_umrah_documents_booking_tenant` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_documents_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_documents_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_documents_passenger_tenant` FOREIGN KEY (`company_id`,`umrah_passenger_id`) REFERENCES `umrah_passengers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_documents_uploaded_by_tenant` FOREIGN KEY (`company_id`,`uploaded_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_documents_verified_by_tenant` FOREIGN KEY (`company_id`,`verified_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `umrah_hotel_bookings`
--
ALTER TABLE `umrah_hotel_bookings`
  ADD CONSTRAINT `fk_umrah_hotel_booking_tenant` FOREIGN KEY (`company_id`,`hotel_booking_id`) REFERENCES `hotel_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_hotel_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_hotel_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_hotel_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_hotel_umrah_tenant` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_hotel_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `umrah_packages`
--
ALTER TABLE `umrah_packages`
  ADD CONSTRAINT `fk_umrah_packages_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_packages_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_packages_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_packages_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_umrah_packages_madinah_hotel_tenant` FOREIGN KEY (`company_id`,`madinah_hotel_id`) REFERENCES `hotels` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_packages_makkah_hotel_tenant` FOREIGN KEY (`company_id`,`makkah_hotel_id`) REFERENCES `hotels` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_packages_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `umrah_passengers`
--
ALTER TABLE `umrah_passengers`
  ADD CONSTRAINT `fk_umrah_passengers_booking_tenant` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_passengers_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_passengers_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_passengers_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_passengers_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_umrah_passengers_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_passengers_family_member_tenant` FOREIGN KEY (`company_id`,`family_member_id`) REFERENCES `family_members` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_passengers_nationality` FOREIGN KEY (`nationality_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_umrah_passengers_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `umrah_ticket_bookings`
--
ALTER TABLE `umrah_ticket_bookings`
  ADD CONSTRAINT `fk_umrah_ticket_booking_tenant` FOREIGN KEY (`company_id`,`ticket_booking_id`) REFERENCES `ticket_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_ticket_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_ticket_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_ticket_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_ticket_passenger_tenant` FOREIGN KEY (`company_id`,`umrah_passenger_id`) REFERENCES `umrah_passengers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_ticket_umrah_tenant` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_ticket_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `umrah_transport_bookings`
--
ALTER TABLE `umrah_transport_bookings`
  ADD CONSTRAINT `fk_umrah_transport_booking_tenant` FOREIGN KEY (`company_id`,`transport_booking_id`) REFERENCES `transport_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_transport_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_transport_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_umrah_transport_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_transport_umrah_tenant` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_umrah_transport_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `users`
--
ALTER TABLE `users`
  ADD CONSTRAINT `fk_user_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_user_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_user_language` FOREIGN KEY (`language_code`) REFERENCES `languages` (`code`);

--
-- Constraints for table `user_roles`
--
ALTER TABLE `user_roles`
  ADD CONSTRAINT `fk_ur_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_ur_role_tenant` FOREIGN KEY (`company_id`,`role_id`) REFERENCES `roles` (`company_id`, `id`),
  ADD CONSTRAINT `fk_ur_user_tenant` FOREIGN KEY (`company_id`,`user_id`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `vehicles`
--
ALTER TABLE `vehicles`
  ADD CONSTRAINT `fk_vehicles_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_vehicles_city` FOREIGN KEY (`city_id`) REFERENCES `cities` (`id`),
  ADD CONSTRAINT `fk_vehicles_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_vehicles_country` FOREIGN KEY (`country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_vehicles_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_vehicles_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_vehicles_supplier_tenant` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_vehicles_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
-- Constraints for table `visas`
--
ALTER TABLE `visas`
  ADD CONSTRAINT `fk_visas_agency_tenant` FOREIGN KEY (`company_id`,`agency_id`) REFERENCES `agencies` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_branch_tenant` FOREIGN KEY (`company_id`,`branch_id`) REFERENCES `branches` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_company` FOREIGN KEY (`company_id`) REFERENCES `companies` (`id`),
  ADD CONSTRAINT `fk_visas_created_by_tenant` FOREIGN KEY (`company_id`,`created_by`) REFERENCES `users` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_currency` FOREIGN KEY (`currency_code`) REFERENCES `currencies` (`code`),
  ADD CONSTRAINT `fk_visas_customer_tenant` FOREIGN KEY (`company_id`,`customer_id`) REFERENCES `customers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_debtor_tenant` FOREIGN KEY (`company_id`,`debtor_id`) REFERENCES `debtors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_destination_country` FOREIGN KEY (`destination_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_visas_foreign_visitor_tenant` FOREIGN KEY (`company_id`,`foreign_visitor_id`) REFERENCES `foreign_visitors` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_issuing_country` FOREIGN KEY (`issuing_country_id`) REFERENCES `countries` (`id`),
  ADD CONSTRAINT `fk_visas_supplier_tenant` FOREIGN KEY (`company_id`,`supplier_id`) REFERENCES `suppliers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_umrah_booking_tenant` FOREIGN KEY (`company_id`,`umrah_booking_id`) REFERENCES `umrah_bookings` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_umrah_passenger_tenant` FOREIGN KEY (`company_id`,`umrah_passenger_id`) REFERENCES `umrah_passengers` (`company_id`, `id`),
  ADD CONSTRAINT `fk_visas_updated_by_tenant` FOREIGN KEY (`company_id`,`updated_by`) REFERENCES `users` (`company_id`, `id`);

--
--

--
--

--
--
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
