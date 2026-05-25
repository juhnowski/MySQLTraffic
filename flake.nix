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
        ps.mysql-connector
      ]);
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          pkgs.cargo
          pkgs.rustc
          pkgs.mysql84
          pythonEnv
        ];

                shellHook = ''
          # Разделяем папки: конфигурация в корне, данные — в изолированной папке
          export MSL_DIR="$(pwd)/mysql_data"
          export MSL_CONF="$(pwd)/my.cnf"
          export MSL_SOCKET="$MSL_DIR/mysql.sock"
          export MSL_PID="$MSL_DIR/mysql.pid"
          export PORT=3307
          
          if [ ! -f "$MSL_CONF" ]; then
            echo "[Nix] Создание изолированной конфигурации MySQL в корне..."
            cat <<EOF > "$MSL_CONF"
[mysqld]
datadir = $MSL_DIR
socket = $MSL_SOCKET
pid-file = $MSL_PID
port = $PORT
bind-address = 127.0.0.1
mysqlx = OFF

ssl_ca = $MSL_DIR/ca.pem
ssl_cert = $MSL_DIR/server-cert.pem
ssl_key = $MSL_DIR/server-key.pem
secure_file_priv = $MSL_DIR

# Тюнинг под сбор сырых 16КБ блоков
innodb_file_per_table = 1
innodb_buffer_pool_size = 64M
innodb_flush_log_at_trx_commit = 1
innodb_doublewrite = 0
innodb_stats_on_metadata = 0
EOF
          fi

          # Инициализируем только если папка данных физически пуста или отсутствует
          if [ ! -d "$MSL_DIR" ] || [ -z "$(ls -A "$MSL_DIR")" ]; then
            echo "[Nix] Создание чистой папки данных и инициализация словаря..."
            mkdir -p "$MSL_DIR"
            mysqld --defaults-file="$MSL_CONF" --initialize-insecure
          fi

          echo "--------------------------------------------------------"
          echo " Доступные команды MySQL-стенда:"
          echo "   start-mysql - Запустить локальный сервер MySQL"
          echo "   stop-mysql  - Остановить сервер MySQL"
          echo "   run-bench   - Сгенерировать данные и собрать blocks (.ibd)"
          echo "   run-entropy - Вычислить энтропию"
          echo "--------------------------------------------------------"

          alias start-mysql="mysqld --defaults-file=\$MSL_CONF > \$MSL_DIR/mysql.log 2>&1 &"
          alias stop-mysql="mysqladmin --socket=\$MSL_SOCKET -u root shutdown"
          alias run-bench="python collect_mysql_blocks.py"
          alias run-entropy="cargo run --release --manifest-path=\$(pwd)/entropy_analyzer/Cargo.toml --"
        '';


      };
    };
}
