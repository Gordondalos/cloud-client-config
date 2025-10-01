-- Patch to add `code` column expected by application views/migrations
-- Safe to run multiple times (IF NOT EXISTS is supported in MySQL 8.0)

USE fnt;

ALTER TABLE `region`            ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `result_contact`    ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `jewels`            ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `arrival_way`       ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `issue_authority`   ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `passport_series`   ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `reliability`       ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `text_info`         ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `moneyflow_types`   ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `printers`          ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `jevel_descriptions` ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
ALTER TABLE `paper_types`       ADD COLUMN IF NOT EXISTS `code` varchar(255) NULL;
