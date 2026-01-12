#!/bin/bash
# Performance tracking library for run.sh scripts
# Provides hierarchical performance tracking (wall-clock time) for phases and steps
#
# Usage:
#   source "$REPO_ROOT/run_scripts/shared/performance-tracker.sh"
#   perf_init
#   perf_phase_start 0 "Prerequisites"
#   perf_step_start 0 "0.1" "Checking prerequisites"
#   # ... execute step ...
#   perf_step_end 0 "0.1" "SUCCESS" "Prerequisites checked"
#   perf_phase_end 0
#   perf_print_summary
#   perf_print_statistics

# Global variables
PERF_START_TIME=""
PERF_DATA_FILE=""
PERF_INITIALIZED=false

# Check if jq is available (for JSON parsing)
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

HAS_JQ=false
if command_exists jq; then
    HAS_JQ=true
fi

# Initialize performance tracking
perf_init() {
    PERF_START_TIME=$(date +%s)
    PERF_DATA_FILE=$(mktemp)
    PERF_INITIALIZED=true
    
    # Initialize JSON structure
    if [ "$HAS_JQ" = true ]; then
        echo '{"start_time":'$PERF_START_TIME',"phases":{}}' > "$PERF_DATA_FILE"
    else
        # Simple bash-only structure using associative arrays
        declare -gA PERF_PHASE_START
        declare -gA PERF_PHASE_END
        declare -gA PERF_PHASE_NAME
        declare -gA PERF_STEP_START
        declare -gA PERF_STEP_END
        declare -gA PERF_STEP_NAME
        declare -gA PERF_STEP_STATUS
        declare -gA PERF_STEP_ELAPSED
    fi
    
    # Setup trap to print summary on exit
    trap 'perf_print_summary; perf_print_statistics' EXIT
}

# Start phase timing
perf_phase_start() {
    local phase_num=$1
    local phase_name=$2
    local start_time=$(date +%s)
    
    if [ "$PERF_INITIALIZED" != "true" ]; then
        return 0  # Silently fail if not initialized
    fi
    
    if [ "$HAS_JQ" = true ]; then
        # Update JSON using jq
        local temp_file=$(mktemp)
        jq --arg pn "$phase_num" \
           --arg name "$phase_name" \
           --argjson start "$start_time" \
           '.phases[$pn] = {
             "name": $name,
             "start": $start,
             "end": null,
             "elapsed": null,
             "steps": {}
           }' "$PERF_DATA_FILE" > "$temp_file"
        mv "$temp_file" "$PERF_DATA_FILE"
    else
        # Store in associative arrays
        PERF_PHASE_START["$phase_num"]=$start_time
        PERF_PHASE_NAME["$phase_num"]="$phase_name"
    fi
}

# End phase timing
perf_phase_end() {
    local phase_num=$1
    local end_time=$(date +%s)
    
    if [ "$PERF_INITIALIZED" != "true" ]; then
        return 0
    fi
    
    if [ "$HAS_JQ" = true ]; then
        local start_time=$(jq -r ".phases[\"$phase_num\"].start // 0" "$PERF_DATA_FILE")
        if [ "$start_time" != "0" ] && [ "$start_time" != "null" ]; then
            local elapsed=$((end_time - start_time))
            local temp_file=$(mktemp)
            jq --arg pn "$phase_num" \
               --argjson end "$end_time" \
               --argjson elapsed "$elapsed" \
               '.phases[$pn].end = $end | .phases[$pn].elapsed = $elapsed' \
               "$PERF_DATA_FILE" > "$temp_file"
            mv "$temp_file" "$PERF_DATA_FILE"
        fi
    else
        local start_time="${PERF_PHASE_START[$phase_num]:-0}"
        if [ "$start_time" != "0" ]; then
            PERF_PHASE_END["$phase_num"]=$end_time
        fi
    fi
}

# Start step timing
perf_step_start() {
    local phase_num=$1
    local step_num=$2
    local step_name=$3
    local start_time=$(date +%s)
    
    if [ "$PERF_INITIALIZED" != "true" ]; then
        return 0
    fi
    
    if [ "$HAS_JQ" = true ]; then
        local temp_file=$(mktemp)
        jq --arg pn "$phase_num" \
           --arg sn "$step_num" \
           --arg name "$step_name" \
           --argjson start "$start_time" \
           '.phases[$pn].steps[$sn] = {
             "name": $name,
             "start": $start,
             "end": null,
             "elapsed": null,
             "status": null
           }' "$PERF_DATA_FILE" > "$temp_file"
        mv "$temp_file" "$PERF_DATA_FILE"
    else
        local key="${phase_num}_${step_num}"
        PERF_STEP_START["$key"]=$start_time
        PERF_STEP_NAME["$key"]="$step_name"
    fi
}

# End step timing
perf_step_end() {
    local phase_num=$1
    local step_num=$2
    local status=$3  # SUCCESS, FAILED, SKIPPED
    local message=$4
    local end_time=$(date +%s)
    
    if [ "$PERF_INITIALIZED" != "true" ]; then
        return 0
    fi
    
    if [ "$HAS_JQ" = true ]; then
        local start_time=$(jq -r ".phases[\"$phase_num\"].steps[\"$step_num\"].start // 0" "$PERF_DATA_FILE")
        if [ "$start_time" != "0" ] && [ "$start_time" != "null" ]; then
            local elapsed=$((end_time - start_time))
            local temp_file=$(mktemp)
            jq --arg pn "$phase_num" \
               --arg sn "$step_num" \
               --arg status "$status" \
               --argjson end "$end_time" \
               --argjson elapsed "$elapsed" \
               '.phases[$pn].steps[$sn].end = $end | 
                .phases[$pn].steps[$sn].elapsed = $elapsed | 
                .phases[$pn].steps[$sn].status = $status' \
               "$PERF_DATA_FILE" > "$temp_file"
            mv "$temp_file" "$PERF_DATA_FILE"
        fi
    else
        local key="${phase_num}_${step_num}"
        local start_time="${PERF_STEP_START[$key]:-0}"
        if [ "$start_time" != "0" ]; then
            PERF_STEP_END["$key"]=$end_time
            PERF_STEP_STATUS["$key"]="$status"
            local elapsed=$((end_time - start_time))
            PERF_STEP_ELAPSED["$key"]=$elapsed
        fi
    fi
}

# Format elapsed time (reuse from logger.sh if available, otherwise define here)
format_elapsed_time() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        local secs=$((seconds % 60))
        echo "${hours}h ${mins}m ${secs}s"
    fi
}

# Print hierarchical summary
perf_print_summary() {
    if [ "$PERF_INITIALIZED" != "true" ]; then
        return 0
    fi
    
    local total_elapsed=$(( $(date +%s) - PERF_START_TIME ))
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "PERFORMANCE SUMMARY"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Total Execution Time: $(format_elapsed_time $total_elapsed)"
    echo ""
    
    if [ "$HAS_JQ" = true ]; then
        # Print using jq
        local phase_nums=$(jq -r '.phases | keys[]' "$PERF_DATA_FILE" | sort -n)
        for phase_num in $phase_nums; do
            local phase_name=$(jq -r ".phases[\"$phase_num\"].name" "$PERF_DATA_FILE")
            local phase_elapsed=$(jq -r ".phases[\"$phase_num\"].elapsed // 0" "$PERF_DATA_FILE")
            
            if [ "$phase_elapsed" != "0" ] && [ "$phase_elapsed" != "null" ]; then
                echo "Phase $phase_num: $phase_name ($(format_elapsed_time $phase_elapsed))"
                
                # Print steps in this phase
                local step_nums=$(jq -r ".phases[\"$phase_num\"].steps | keys[]" "$PERF_DATA_FILE" | sort -n)
                for step_num in $step_nums; do
                    local step_name=$(jq -r ".phases[\"$phase_num\"].steps[\"$step_num\"].name" "$PERF_DATA_FILE")
                    local step_elapsed=$(jq -r ".phases[\"$phase_num\"].steps[\"$step_num\"].elapsed // 0" "$PERF_DATA_FILE")
                    local step_status=$(jq -r ".phases[\"$phase_num\"].steps[\"$step_num\"].status // \"UNKNOWN\"" "$PERF_DATA_FILE")
                    
                    if [ "$step_elapsed" != "0" ] && [ "$step_elapsed" != "null" ]; then
                        local status_label="[UNKNOWN]"
                        case "$step_status" in
                            "SUCCESS") status_label="[PASSED]" ;;
                            "FAILED") status_label="[FAILED]" ;;
                            "SKIPPED") status_label="[SKIPPED]" ;;
                        esac
                        printf "  Step %s: %-50s %6s %s\n" "$step_num" "$step_name" "$(format_elapsed_time $step_elapsed)" "$status_label"
                    fi
                done
                echo ""
            fi
        done
    else
        # Print using associative arrays (bash-only)
        for phase_num in "${!PERF_PHASE_START[@]}"; do
            local phase_name="${PERF_PHASE_NAME[$phase_num]}"
            local phase_start="${PERF_PHASE_START[$phase_num]}"
            local phase_end="${PERF_PHASE_END[$phase_num]:-$PERF_START_TIME}"
            local phase_elapsed=$((phase_end - phase_start))
            
            echo "Phase $phase_num: $phase_name ($(format_elapsed_time $phase_elapsed))"
            
            # Print steps in this phase
            for key in "${!PERF_STEP_START[@]}"; do
                if [[ "$key" =~ ^${phase_num}_ ]]; then
                    local step_num="${key#${phase_num}_}"
                    local step_name="${PERF_STEP_NAME[$key]}"
                    local step_elapsed="${PERF_STEP_ELAPSED[$key]:-0}"
                    local step_status="${PERF_STEP_STATUS[$key]:-UNKNOWN}"
                    
                    if [ "$step_elapsed" != "0" ]; then
                        local status_label="[UNKNOWN]"
                        case "$step_status" in
                            "SUCCESS") status_label="[PASSED]" ;;
                            "FAILED") status_label="[FAILED]" ;;
                            "SKIPPED") status_label="[SKIPPED]" ;;
                        esac
                        printf "  Step %s: %-50s %6s %s\n" "$step_num" "$step_name" "$(format_elapsed_time $step_elapsed)" "$status_label"
                    fi
                fi
            done
            echo ""
        done
    fi
}

# Print statistics
perf_print_statistics() {
    if [ "$PERF_INITIALIZED" != "true" ]; then
        return 0
    fi
    
    local total_elapsed=$(( $(date +%s) - PERF_START_TIME ))
    
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "PERFORMANCE STATISTICS"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    
    local total_phases=0
    local total_steps=0
    local skipped_steps=0
    local failed_steps=0
    local min_step_time=999999
    local max_step_time=0
    local min_step_phase=""
    local min_step_num=""
    local max_step_phase=""
    local max_step_num=""
    local total_step_time=0
    
    if [ "$HAS_JQ" = true ]; then
        # Calculate statistics using jq
        local phase_nums=$(jq -r '.phases | keys[]' "$PERF_DATA_FILE" | sort -n)
        for phase_num in $phase_nums; do
            local phase_elapsed=$(jq -r ".phases[\"$phase_num\"].elapsed // 0" "$PERF_DATA_FILE")
            if [ "$phase_elapsed" != "0" ] && [ "$phase_elapsed" != "null" ]; then
                total_phases=$((total_phases + 1))
            fi
            
            # Count steps
            local step_nums=$(jq -r ".phases[\"$phase_num\"].steps | keys[]" "$PERF_DATA_FILE" 2>/dev/null | sort -n)
            for step_num in $step_nums; do
                local step_elapsed=$(jq -r ".phases[\"$phase_num\"].steps[\"$step_num\"].elapsed // 0" "$PERF_DATA_FILE")
                local step_status=$(jq -r ".phases[\"$phase_num\"].steps[\"$step_num\"].status // \"UNKNOWN\"" "$PERF_DATA_FILE")
                
                if [ "$step_elapsed" != "0" ] && [ "$step_elapsed" != "null" ]; then
                    total_steps=$((total_steps + 1))
                    
                    case "$step_status" in
                        "SKIPPED") skipped_steps=$((skipped_steps + 1)) ;;
                        "FAILED") failed_steps=$((failed_steps + 1)) ;;
                    esac
                    
                    # Only include successful/failed steps in min/max/avg (not skipped)
                    if [ "$step_status" != "SKIPPED" ]; then
                        total_step_time=$((total_step_time + step_elapsed))
                        
                        if [ "$step_elapsed" -lt "$min_step_time" ]; then
                            min_step_time=$step_elapsed
                            min_step_phase="$phase_num"
                            min_step_num="$step_num"
                        fi
                        
                        if [ "$step_elapsed" -gt "$max_step_time" ]; then
                            max_step_time=$step_elapsed
                            max_step_phase="$phase_num"
                            max_step_num="$step_num"
                        fi
                    fi
                fi
            done
        done
    else
        # Calculate statistics using associative arrays
        total_phases=${#PERF_PHASE_START[@]}
        
        for key in "${!PERF_STEP_START[@]}"; do
            local step_elapsed="${PERF_STEP_ELAPSED[$key]:-0}"
            local step_status="${PERF_STEP_STATUS[$key]:-UNKNOWN}"
            
            if [ "$step_elapsed" != "0" ]; then
                total_steps=$((total_steps + 1))
                
                case "$step_status" in
                    "SKIPPED") skipped_steps=$((skipped_steps + 1)) ;;
                    "FAILED") failed_steps=$((failed_steps + 1)) ;;
                esac
                
                if [ "$step_status" != "SKIPPED" ]; then
                    total_step_time=$((total_step_time + step_elapsed))
                    
                    if [ "$step_elapsed" -lt "$min_step_time" ]; then
                        min_step_time=$step_elapsed
                        local phase_num="${key%%_*}"
                        local step_num="${key#*_}"
                        min_step_phase="$phase_num"
                        min_step_num="$step_num"
                    fi
                    
                    if [ "$step_elapsed" -gt "$max_step_time" ]; then
                        max_step_time=$step_elapsed
                        local phase_num="${key%%_*}"
                        local step_num="${key#*_}"
                        max_step_phase="$phase_num"
                        max_step_num="$step_num"
                    fi
                fi
            fi
        done
    fi
    
    # Print statistics
    echo "Total Phases: $total_phases"
    echo "Total Steps: $total_steps"
    
    if [ "$min_step_time" != "999999" ] && [ "$max_step_time" != "0" ]; then
        local min_step_name=""
        local max_step_name=""
        
        if [ "$HAS_JQ" = true ]; then
            min_step_name=$(jq -r ".phases[\"$min_step_phase\"].steps[\"$min_step_num\"].name // \"Unknown\"" "$PERF_DATA_FILE" 2>/dev/null)
            max_step_name=$(jq -r ".phases[\"$max_step_phase\"].steps[\"$max_step_num\"].name // \"Unknown\"" "$PERF_DATA_FILE" 2>/dev/null)
        else
            min_step_name="${PERF_STEP_NAME[${min_step_phase}_${min_step_num}]:-Unknown}"
            max_step_name="${PERF_STEP_NAME[${max_step_phase}_${max_step_num}]:-Unknown}"
        fi
        
        echo "Fastest Step: Phase $min_step_phase: Step $min_step_num - $min_step_name ($(format_elapsed_time $min_step_time))"
        echo "Slowest Step: Phase $max_step_phase: Step $max_step_num - $max_step_name ($(format_elapsed_time $max_step_time))"
        
        local avg_steps=$((total_steps - skipped_steps))
        if [ "$avg_steps" -gt 0 ]; then
            local avg_time=$((total_step_time / avg_steps))
            echo "Average Step Time: $(format_elapsed_time $avg_time)"
        fi
    fi
    
    if [ "$skipped_steps" -gt 0 ]; then
        echo "Steps Skipped: $skipped_steps"
    fi
    
    if [ "$failed_steps" -gt 0 ]; then
        echo "Steps Failed: $failed_steps"
    fi
    
    echo ""
    echo "Phase Breakdown:"
    
    if [ "$HAS_JQ" = true ]; then
        local phase_nums=$(jq -r '.phases | keys[]' "$PERF_DATA_FILE" | sort -n)
        for phase_num in $phase_nums; do
            local phase_name=$(jq -r ".phases[\"$phase_num\"].name" "$PERF_DATA_FILE")
            local phase_elapsed=$(jq -r ".phases[\"$phase_num\"].elapsed // 0" "$PERF_DATA_FILE")
            
            if [ "$phase_elapsed" != "0" ] && [ "$phase_elapsed" != "null" ]; then
                local percentage=$((phase_elapsed * 100 / total_elapsed))
                echo "  Phase $phase_num: $(format_elapsed_time $phase_elapsed)  ($percentage% of total)"
            fi
        done
    else
        for phase_num in "${!PERF_PHASE_START[@]}"; do
            local phase_name="${PERF_PHASE_NAME[$phase_num]}"
            local phase_start="${PERF_PHASE_START[$phase_num]}"
            local phase_end="${PERF_PHASE_END[$phase_num]:-$PERF_START_TIME}"
            local phase_elapsed=$((phase_end - phase_start))
            
            if [ "$phase_elapsed" -gt 0 ]; then
                local percentage=$((phase_elapsed * 100 / total_elapsed))
                echo "  Phase $phase_num: $(format_elapsed_time $phase_elapsed)  ($percentage% of total)"
            fi
        done
    fi
    
    echo ""
    
    # Cleanup temp file
    if [ -n "$PERF_DATA_FILE" ] && [ -f "$PERF_DATA_FILE" ]; then
        rm -f "$PERF_DATA_FILE"
    fi
}

