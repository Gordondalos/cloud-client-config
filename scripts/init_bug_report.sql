-- Ensure minimal table for upstream migration UpdateUidInBugReportIfNotExist1717849287648
-- The migration executes: UPDATE bug_report SET uid = (SELECT UUID()) WHERE uid IS NULL
-- This script creates a compatible baseline table if it's missing in the dump.

CREATE TABLE IF NOT EXISTS `bug_report` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` datetime NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
  `title` varchar(255) DEFAULT NULL,
  `description` text,
  `uid` char(36) NULL,
  PRIMARY KEY (`id`),
  KEY `bug_report_uid_idx` (`uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;