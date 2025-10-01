-- Ensure minimal table for upstream migrations (uid backfill and index creation)
-- Migrations expect table fnt.bug_report with columns at least: uid, type (for indexing)
-- 1) Create table if not exists (includes `type`, `status`, `date_create` for downstream indexes)
-- 2) Ensure missing columns exist even if table already присутствует из старого дампа

CREATE TABLE IF NOT EXISTS `bug_report` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
  `title` varchar(255) DEFAULT NULL,
  `description` text,
  `type` varchar(255) NULL,
  `status` smallint NULL,
  `date_create` datetime NULL DEFAULT CURRENT_TIMESTAMP,
  `uid` char(36) NULL,
  PRIMARY KEY (`id`),
  KEY `bug_report_uid_idx` (`uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

-- Ensure `type` column exists (idempotent)
SET @stmt := (
  SELECT IF(
    EXISTS(
      SELECT 1
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'bug_report'
        AND COLUMN_NAME = 'type'
    ),
    'SELECT 1',
    'ALTER TABLE `bug_report` ADD COLUMN `type` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- Ensure `status` column exists (idempotent)
SET @stmt := (
  SELECT IF(
    EXISTS(
      SELECT 1
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'bug_report'
        AND COLUMN_NAME = 'status'
    ),
    'SELECT 1',
    'ALTER TABLE `bug_report` ADD COLUMN `status` smallint NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- Ensure `date_create` column exists (idempotent)
SET @stmt := (
  SELECT IF(
    EXISTS(
      SELECT 1
      FROM INFORMATION_SCHEMA.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'bug_report'
        AND COLUMN_NAME = 'date_create'
    ),
    'SELECT 1',
    'ALTER TABLE `bug_report` ADD COLUMN `date_create` datetime NULL DEFAULT CURRENT_TIMESTAMP'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;