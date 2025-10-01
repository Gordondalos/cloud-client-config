-- Patch to add `code` column expected by application views/migrations
-- Idempotent and compatible with older MySQL versions (no IF NOT EXISTS on ADD COLUMN)

USE fnt;

-- Helper pattern: build a statement based on INFORMATION_SCHEMA check
-- Then PREPARE/EXECUTE it; otherwise run a harmless SELECT 1

-- region.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'region' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `region` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- result_contact.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'result_contact' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `result_contact` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- jewels.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'jewels' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `jewels` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- arrival_way.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'arrival_way' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `arrival_way` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- issue_authority.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'issue_authority' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `issue_authority` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- passport_series.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'passport_series' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `passport_series` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- reliability.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'reliability' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `reliability` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- text_info.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'text_info' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `text_info` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- moneyflow_types.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'moneyflow_types' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `moneyflow_types` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- printers.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'printers' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `printers` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- jevel_descriptions.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'jevel_descriptions' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `jevel_descriptions` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;

-- paper_types.code
SET @stmt = (
  SELECT IF(
    EXISTS(SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'paper_types' AND COLUMN_NAME = 'code'),
    'SELECT 1',
    'ALTER TABLE `paper_types` ADD COLUMN `code` varchar(255) NULL'
  )
);
PREPARE s FROM @stmt; EXECUTE s; DEALLOCATE PREPARE s;
