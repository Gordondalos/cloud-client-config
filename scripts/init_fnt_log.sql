--
-- Инициализация схемы fnt_log: создание таблицы log без наполнения данными
-- Скрипт основан на исходном дампе (dbForge 2019), очищен от INSERT и TRUNCATE
--

-- Отключение внешних ключей
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;

-- Установить режим SQL (SQL mode)
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;

-- Установка кодировки для клиента
SET NAMES 'utf8';

-- Установка базы данных по умолчанию
USE fnt_log;

-- На чистой установке таблицы может и не быть; на повторном запуске удаляем и пересоздаём
DROP TABLE IF EXISTS log;

-- Создать таблицу `log`
CREATE TABLE log (
  id int(11) UNSIGNED NOT NULL AUTO_INCREMENT,
  user_create_id int(11) UNSIGNED NOT NULL,
  filial_id int(11) UNSIGNED NOT NULL,
  body json DEFAULT NULL,
  param json DEFAULT NULL,
  message json DEFAULT NULL,
  tag varchar(255) DEFAULT NULL,
  original_url varchar(255) NOT NULL,
  http_method varchar(5) NOT NULL,
  client_ip varchar(25) NOT NULL,
  date_create datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
)
ENGINE = INNODB,
CHARACTER SET utf8,
COLLATE utf8_general_ci;

-- Восстановить предыдущий режим SQL (SQL mode)
/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;

-- Включение внешних ключей
/*!40014 SET FOREIGN_KEY_CHECKS = @OLD_FOREIGN_KEY_CHECKS */;
