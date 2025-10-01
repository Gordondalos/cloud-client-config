ALTER USER 'root'@'localhost' IDENTIFIED BY '212354568789';

CREATE USER IF NOT EXISTS  'enlighted'@'%' identified by '(VanHalen10)';
CREATE USER IF NOT EXISTS  'gordondalos'@'%' identified by '212354568789';

grant all privileges on fnt.* to 'gordondalos'@'%';
grant all privileges on fnt_log.* to 'gordondalos'@'%';
FLUSH PRIVILEGES;

grant all privileges on fnt.* to 'enlighted'@'%';
grant all privileges on fnt_log.* to 'enlighted'@'%';
FLUSH PRIVILEGES;

GRANT ALL PRIVILEGES ON *.* TO 'gordondalos'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'enlighted'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;

CREATE DATABASE IF NOT EXISTS fnt_log;
CREATE DATABASE IF NOT EXISTS license_db;

SET GLOBAL sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

SHOW DATABASES;




