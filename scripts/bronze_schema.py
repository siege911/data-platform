import psycopg2
import csv
import os
from typing import List, Dict
from dotenv import load_dotenv

def get_database_connection():
    """Load connection details from .env file and return connection."""
    # Load .env file from parent directory
    env_path = os.path.join(os.path.dirname(__file__), '..', '.env')
    load_dotenv(env_path)
    
    # Get connection details from environment variables
    host = os.getenv('POSTGRES_HOST', 'localhost')
    port = os.getenv('POSTGRES_PORT', '5432')
    database = os.getenv('POSTGRES_DB')
    user = os.getenv('POSTGRES_USER')
    password = os.getenv('POSTGRES_PASSWORD')
    
    # Validate required variables
    if not all([database, user, password]):
        raise ValueError(
            "Missing required environment variables. "
            "Please ensure DB_NAME, DB_USER, and DB_PASSWORD are set in .env file"
        )
    
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=user,
            password=password
        )
        print(f"✓ Connected to database '{database}' at {host}:{port}\n")
        return conn
    except psycopg2.Error as e:
        print(f"✗ Connection failed: {e}")
        raise

def get_table_names(conn, table_prefix: str) -> List[str]:
    """Get all table names in bronze schema that start with the prefix."""
    query = """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'bronze'
          AND table_name LIKE %s
        ORDER BY table_name;
    """
    
    cursor = conn.cursor()
    cursor.execute(query, (f"{table_prefix}%",))
    tables = [row[0] for row in cursor.fetchall()]
    cursor.close()
    
    return tables

def get_output_dir():
    """Get or create the schema_output directory in the script's folder."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.join(script_dir, 'schema_output')
    
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        print(f"✓ Created output directory: {output_dir}\n")
    
    return output_dir

def export_schema_details(conn, table_prefix: str, tables: List[str], output_dir: str):
    """Export schema details for all matching tables to bronze_schema.csv."""
    query = """
        SELECT 
            table_name,
            column_name,
            data_type,
            character_maximum_length,
            numeric_precision,
            numeric_scale,
            is_nullable,
            column_default,
            ordinal_position
        FROM 
            information_schema.columns
        WHERE 
            table_schema = 'bronze'
            AND table_name LIKE %s
        ORDER BY 
            table_name,
            ordinal_position;
    """
    
    cursor = conn.cursor()
    cursor.execute(query, (f"{table_prefix}%",))
    
    output_path = os.path.join(output_dir, 'bronze_schema.csv')
    with open(output_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow([
            'table_name', 'column_name', 'data_type', 
            'character_maximum_length', 'numeric_precision', 'numeric_scale',
            'is_nullable', 'column_default', 'ordinal_position'
        ])
        writer.writerows(cursor.fetchall())
    
    cursor.close()
    print(f"✓ Schema exported to bronze_schema.csv")

def export_sample_data(conn, table_name: str, output_dir: str):
    """Export first 10 rows of a table to a CSV file."""
    query = f'SELECT * FROM bronze."{table_name}" LIMIT 10;'
    
    cursor = conn.cursor()
    try:
        cursor.execute(query)
        rows = cursor.fetchall()
        
        if rows:
            # Get column names from cursor description
            column_names = [desc[0] for desc in cursor.description]
            
            filename = f"{table_name}_sample_rows.csv"
            output_path = os.path.join(output_dir, filename)
            with open(output_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                writer.writerow(column_names)
                writer.writerows(rows)
            
            print(f"  ✓ Exported {len(rows)} rows to {filename}")
        else:
            print(f"  ⚠ Table {table_name} is empty, skipping sample export")
    
    except psycopg2.Error as e:
        print(f"  ✗ Error exporting {table_name}: {e}")
    finally:
        cursor.close()

def main():
    print("=== PostgreSQL Bronze Schema Exporter ===\n")
    
    # Get or create output directory
    output_dir = get_output_dir()
    
    # Get database connection
    try:
        conn = get_database_connection()
    except:
        return
    
    # Get table prefix
    table_prefix = input("Enter table prefix (or press Enter for all tables): ").strip()
    print()
    
    try:
        # Get matching tables
        tables = get_table_names(conn, table_prefix)
        
        if not tables:
            print(f"No tables found in 'bronze' schema with prefix '{table_prefix}'")
            return
        
        print(f"Found {len(tables)} table(s) matching prefix '{table_prefix}':")
        for table in tables:
            print(f"  - {table}")
        print()
        
        # Export schema details
        print("Exporting schema details...")
        export_schema_details(conn, table_prefix, tables, output_dir)
        print()
        
        # Export sample data for each table
        print("Exporting sample data for each table...")
        for table in tables:
            export_sample_data(conn, table, output_dir)
        
        print("\n✓ All exports completed successfully!")
        print(f"\nFiles created in: {output_dir}")
        print(f"  - bronze_schema.csv")
        for table in tables:
            print(f"  - {table}_sample_rows.csv")
        
    except psycopg2.Error as e:
        print(f"Database error: {e}")
    finally:
        conn.close()
        print("\n✓ Database connection closed")

if __name__ == "__main__":
    main()