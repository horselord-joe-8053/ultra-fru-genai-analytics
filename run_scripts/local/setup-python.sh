#!/bin/bash
# Setup Python virtual environment and install dependencies
# Idempotent: checks if venv exists and dependencies are installed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

VENV_DIR="$REPO_ROOT/venv"
REQUIREMENTS_FILE="$REPO_ROOT/requirements.txt"

setup_python_env() {
    log_step "Setting up Python environment"
    
    # Check Python version
    if ! python3 --version | grep -qE "Python 3\.(10|11|12)"; then
        log_error "Python 3.10+ is required. Found: $(python3 --version)"
        exit 1
    fi
    log_success "Python version check passed: $(python3 --version)"
    
    # Create virtual environment if it doesn't exist
    if [ ! -d "$VENV_DIR" ]; then
        log_info "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR"
        log_success "Virtual environment created"
    else
        log_info "Virtual environment already exists"
    fi
    
    # Activate virtual environment
    log_info "Activating virtual environment..."
    source "$VENV_DIR/bin/activate"
    
    # Upgrade pip
    log_info "Upgrading pip..."
    pip install --quiet --upgrade pip
    
    # Install dependencies (idempotent: pip install skips already-installed packages)
    if [ -f "$REQUIREMENTS_FILE" ]; then
        log_info "Installing/updating Python dependencies from requirements.txt..."
        # pip install is idempotent - it will:
        # - Skip packages already installed with matching versions
        # - Upgrade packages if newer version is specified
        # - Install missing packages
        pip install --quiet --upgrade -r "$REQUIREMENTS_FILE"
        log_success "Python dependencies installed/updated"
    else
        log_error "requirements.txt not found at $REQUIREMENTS_FILE"
        exit 1
    fi
    
    # Verify installation
    log_info "Verifying installation..."
    if python -c "import flask, psycopg2, openai, boto3, pandas" 2>/dev/null; then
        log_success "All required packages are installed"
    else
        log_error "Some packages failed to import. Please check the installation."
        exit 1
    fi
}

main() {
    setup_python_env
}

main "$@"

