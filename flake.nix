{
  description = "Стенд для сбора сырых 16КБ блоков данных MySQL (InnoDB)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux"; # Измените на aarch64-linux / x86_64-darwin, если у вас другая платформа
      pkgs = import nixpkgs { inherit system; };
      
      pythonEnv = pkgs.python3.withPackages (ps: [
        ps.mysql-connector-python # Тот же драйвер, отлично работает и с оригинальным MySQL
      ]);
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.mysql      # Чистый дистрибутив MySQL Server
          pythonEnv
        ];

        shellHook = ''
          export MSL_DIR="$PWD/mysql_data"
          export MSL_SOCKET="$MSL_DIR/mysql.sock"
          export MSL_PID="$MSL_DIR/mysql.pid"
          export MSL_CONF="$MSL_DIR/my.cnf"
          export PORT=3306
          
          mkdir -p "$MSL_DIR"

          # Генерируем конфигурацию my.cnf специально для MySQL 8.x/9.x
          if [ ! -f "$MSL_CONF" ]; then
            echo "[Nix] Создание изолированной конфигурации MySQL..."
            cat <<EOF > "$MSL_CONF"
[mysqld]
user = ${builtins.getEnv "USER"}
datadir = $MSL_DIR
socket = $MSL_SOCKET
pid-file = $MSL_PID
port = $PORT
bind-address = 127.0.0.1
mysqlx = OFF # Отключаем X-Plugin для экономии ресурсов стенда

# Тюнинг InnoDB под замер сырых страниц данных
innodb_file_per_table = 1          # Каждая таблица пишется в свой .ibd файл
innodb_buffer_pool_size = 64M      # Минимальный буфер для быстрого вытеснения страниц на диск
innodb_flush_log_at_trx_commit = 1 # Немедленный сброс транзакционных логов
innodb_doublewrite = 0             # КРИТИЧНО: Отключаем двойную запись, чтобы блоки не дублировались в системных файлах
innodb_stats_on_metadata = 0
EOF

            echo "[Nix] Инициализация системного словаря данных MySQL..."
            # Инициализируем БД в режиме insecure (без пароля для root)
            mysqld --defaults-file="$MSL_CONF" --initialize-insecure
          fi

          echo "--------------------------------------------------------"
          echo " Доступные команды MySQL-стенда:"
          echo "   start-mysql - Запустить локальный сервер MySQL"
          echo "   stop-mysql  - Остановить сервер MySQL"
          echo "   run-bench   - Сгенерировать данные и собрать блоки (.ibd)"
          echo "--------------------------------------------------------"

          alias start-mysql="mysqld --defaults-file=\$MSL_CONF --daemonize"
          alias stop-mysql="mysqladmin --socket=\$MSL_SOCKET -u root shutdown"
          alias run-bench="python collect_mysql_blocks.py"
        '';
      };
    };
}
