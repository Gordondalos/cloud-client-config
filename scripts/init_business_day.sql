-- Ensure minimal table for upstream migrations that add index on (date_open)
-- This script is idempotent and safe to re-run

CREATE TABLE IF NOT EXISTS `business_day` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `date_open` datetime NOT NULL,
  `date_close` datetime NULL DEFAULT NULL,
  `actual` tinyint(1) NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;
