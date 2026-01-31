#!/usr/bin/env python3
"""
Parse SQL file into individual statements, handling parentheses and quotes correctly.

This script reads a SQL file, removes comments, and splits it into individual
statements by semicolons, while properly handling:
- Nested parentheses (e.g., in CREATE TABLE statements)
- String literals with quotes
- Semicolons inside parentheses or strings

Usage:
    parse_sql_statements.py <schema_file>

Output:
    Prints one SQL statement per line to stdout.
"""
import re
import sys


def parse_sql_statements(sql_content):
    """
    Parse SQL content into individual statements.
    
    Args:
        sql_content: String containing SQL statements
        
    Returns:
        List of SQL statement strings
    """
    # Remove comments (-- ...)
    content = re.sub(r'--.*?$', '', sql_content, flags=re.MULTILINE)
    
    # Remove empty lines
    lines = [l.strip() for l in content.split('\n') if l.strip()]
    
    # Join all lines
    sql = ' '.join(lines)
    
    # Split on semicolons that are not inside parentheses or quotes
    statements = []
    current = []
    paren_depth = 0
    in_string = False
    string_char = None
    
    i = 0
    while i < len(sql):
        char = sql[i]
        
        # Handle string literals
        if char in ("'", '"') and (i == 0 or sql[i-1] != '\\'):
            if not in_string:
                in_string = True
                string_char = char
            elif char == string_char:
                in_string = False
                string_char = None
        elif not in_string:
            # Track parentheses depth
            if char == '(':
                paren_depth += 1
            elif char == ')':
                paren_depth -= 1
            elif char == ';' and paren_depth == 0:
                # End of statement (semicolon at top level)
                stmt = ''.join(current).strip()
                if stmt:
                    statements.append(stmt)
                current = []
                # Skip semicolon and any following whitespace
                i += 1
                while i < len(sql) and sql[i] in ' \t\n':
                    i += 1
                continue
        
        current.append(char)
        i += 1
    
    # Add final statement if any
    if current:
        stmt = ''.join(current).strip()
        if stmt:
            statements.append(stmt)
    
    return statements


def main():
    """Main entry point."""
    if len(sys.argv) != 2:
        print("Usage: parse_sql_statements.py <schema_file>", file=sys.stderr)
        sys.exit(1)
    
    schema_file = sys.argv[1]
    
    try:
        with open(schema_file, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        print(f"Error: Schema file not found: {schema_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error reading schema file: {e}", file=sys.stderr)
        sys.exit(1)
    
    statements = parse_sql_statements(content)
    
    # Write statements to output, one per line
    for stmt in statements:
        print(stmt)


if __name__ == '__main__':
    main()

