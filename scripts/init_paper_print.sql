-- Ensure the target database exists (created earlier in db-init.sh)
-- Minimal schema for table fnt.paper_print required by application migrations/views
-- Adjust types as needed in the upstream service; this provides a working baseline.
CREATE TABLE IF NOT EXISTS `paper_print` (
  `id` int unsigned NOT NULL AUTO_INCREMENT,
  `printElementCount` int DEFAULT NULL,
  `printTo` varchar(255) DEFAULT NULL,
  `user_id` smallint unsigned DEFAULT NULL,
  `paper` text,
  `date_create` datetime DEFAULT CURRENT_TIMESTAMP,
  `is_test` tinyint(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  KEY `paper_print_user_id_idx` (`user_id`),
  CONSTRAINT `paper_print_user_id_FK` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;