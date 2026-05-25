import os
import shutil
import mysql.connector

OUTPUT_DIR = "./mysql_bench_blocks"
MSL_DATA_DIR = os.path.join(os.environ.get("MSL_DIR", "./mysql_data"), "mysql_bench")


DB_CONFIG = {
    "user": "root",
    "host": "127.0.0.1",
    "port": 3307
}

mysql_socket = os.environ.get("MSL_SOCKET", "/tmp/mysql.sock")

SCENARIOS = {
    "1_duplicates": {
        "schema": """
            CREATE TABLE test_duplicates (
                id INT AUTO_INCREMENT PRIMARY KEY,
                payload TEXT
            ) ENGINE=InnoDB;
        """,
        "insert": "INSERT INTO test_duplicates (payload) VALUES (%s);",
        "data_gen": lambda: [
            ("ПОВТОРЯЮЩИЙСЯ_ШАБЛОН_ДАННЫХ_ДЛЯ_АНАЛИЗА_БЛОКОВ_MYSQL_А_А_А_А_А_А",) 
            if i % 2 == 0 else 
            ("ДРУГОЙ_ФИКСИРОВАННЫЙ_ТЕКСТ_ДЛЯ_БЕНЧМАРКА_ДЕДУПЛИКАЦИИ_Б_Б_Б_Б_Б",)
            for i in range(40000)
        ]
    },
    "2_updates": {
        "schema": """
            CREATE TABLE test_updates (
                id INT PRIMARY KEY,
                counter INT,
                updated_at TIMESTAMP
            ) ENGINE=InnoDB;
        """,
        "insert": "INSERT INTO test_updates (id, counter, updated_at) VALUES (%s, 0, NOW());",
        "data_gen": lambda: [(i,) for i in range(10000)],
        "post_op": lambda cursor: [
            cursor.execute("UPDATE test_updates SET counter = counter + 1, updated_at = NOW() WHERE id % 2 = 0;"),
            cursor.execute("UPDATE test_updates SET counter = counter + 3, updated_at = NOW() WHERE id % 3 = 0;")
        ]
    },
    "3_denormalized": {
        "schema": """
            CREATE TABLE test_denormalized (
                id INT AUTO_INCREMENT PRIMARY KEY,
                client_segment VARCHAR(100),
                payment_status VARCHAR(100),
                price DECIMAL(10,2)
            ) ENGINE=InnoDB;
        """,
        "insert": "INSERT INTO test_denormalized (client_segment, payment_status, price) VALUES (%s, %s, %s);",
        "data_gen": lambda: [
            (["ENTERPRISE", "SMB", "RETAIL"][i % 3], ["PAID", "PENDING"][i % 2], 500.25 * (i % 5))
            for i in range(30000)
        ]
    },
    "4_json": {
        "schema": """
            CREATE TABLE test_json (
                id INT AUTO_INCREMENT PRIMARY KEY,
                doc JSON
            ) ENGINE=InnoDB;
        """,
        "insert": "INSERT INTO test_json (doc) VALUES (%s);",
        "data_gen": lambda: [
            (f'{{"id": {i}, "type": "event", "payload": "{ "X" * 2000 }"}}',)
            for i in range(3000)
        ]
    },
    "5_binary": {
        "schema": """
            CREATE TABLE test_binary (
                id INT AUTO_INCREMENT PRIMARY KEY,
                raw_bytes LONGBLOB
            ) ENGINE=InnoDB;
        """,
        "insert": "INSERT INTO test_binary (raw_bytes) VALUES (%s);",
        "data_gen": lambda: [(os.urandom(16000),) for _ in range(500)]
    }
}

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    conn = mysql.connector.connect(
    user="root",
    password="",  # Мы инициализировали через --initialize-insecure
    unix_socket=mysql_socket, # КРИТИЧНО: подключаемся через локальный сокет, а не порт
    database="sys" # Или ваша целевая база данных
)
    cursor = conn.cursor()
    
    cursor.execute("CREATE DATABASE IF NOT EXISTS mysql_bench;")
    cursor.execute("USE mysql_bench;")
    
    for name, config in SCENARIOS.items():
        print(f"\n--- Сценарий MySQL: {name} ---")
        table_name = f"test_{name.split('_', 1)[1]}" 
        
        cursor.execute(f"DROP TABLE IF EXISTS {table_name};")
        cursor.execute(config["schema"])
        
        print(f"    Заполнение таблицы данными...")
        rows = config["data_gen"]()
        cursor.executemany(config["insert"], rows)
        conn.commit()
        
        if "post_op" in config:
            print(f"    Модификация данных (эффект устаревания строк в InnoDB)...")
            config["post_op"](cursor)
            conn.commit()
            
        # Принудительно заставляем MySQL перенести все блоки таблицы из RAM на диск
        print(f"    Выгрузка 16КБ страниц в .ibd файл...")
        cursor.execute(f"FLUSH TABLES {table_name} FOR EXPORT;")
        
        # Копируем файл таблицы, пока MySQL удерживает его в консистентном замороженном состоянии
        src_file = os.path.join(MSL_DATA_DIR, f"{table_name}.ibd")
        dest_file = os.path.join(OUTPUT_DIR, f"mysql_{name}.ibd.raw")
        
        if os.path.exists(src_file):
            shutil.copy(src_file, dest_file)
            size_kb = os.path.getsize(dest_file) // 1024
            print(f"    Сохранено: {dest_file} ({size_kb} KB, {size_kb // 16} блоков InnoDB)")
        else:
            print(f"    Ошибка: Файл {table_name}.ibd не найден по пути {src_file}!")
            
        cursor.execute("UNLOCK TABLES;")

    cursor.close()
    conn.close()
    print("\n[+] Сбор блоков для MySQL завершен!")

if __name__ == "__main__":
    main()
