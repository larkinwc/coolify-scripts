#!/bin/bash

# Supabase Docker Compose Conservative Image Updater
# This script updates Docker image tags while preserving flavors and avoiding breaking changes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
OFFICIAL_MODE=false
COMPOSE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --official)
            OFFICIAL_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options] [compose-file]"
            echo ""
            echo "Options:"
            echo "  --official    Use official Supabase tested version combinations"
            echo "  --help, -h    Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 docker-compose.yml                    # Conservative updates"
            echo "  $0 --official docker-compose.yml         # Use official Supabase versions"
            exit 0
            ;;
        *)
            COMPOSE_FILE="$1"
            shift
            ;;
    esac
done

# Set default compose file if not provided
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
BACKUP_FILE="${COMPOSE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Official Supabase tested version matrix (from their GitHub repo)
declare -A OFFICIAL_SUPABASE_VERSIONS=(
    ["supabase/studio"]="2025.06.02-sha-8f2993d"
    ["supabase/postgres"]="17.4.1.042"
    ["supabase/gotrue"]="v2.174.0" 
    ["kong"]="2.8.1"
    ["postgrest/postgrest"]="v12.2.0"
    ["supabase/logflare"]="1.15.4"
    ["timberio/vector"]="0.28.1-alpine"
    ["supabase/realtime"]="v2.36.20"
    ["supabase/storage-api"]="v1.24.4"
    ["darthsim/imgproxy"]="v3.28.0"
    ["supabase/postgres-meta"]="v0.89.3"
    ["supabase/edge-runtime"]="v1.67.4"
    ["minio/minio"]="latest"
    ["minio/mc"]="latest"
)

# Conservative stable versions (for non-official mode)
declare -A CONSERVATIVE_STABLE_VERSIONS=(
    ["supabase/studio"]="2025.06.02"
    ["supabase/postgres"]="15.8.1"
    ["supabase/gotrue"]="v2.174.0" 
    ["kong"]="2.8.1"
    ["postgrest/postgrest"]="v12.2.0"
    ["supabase/logflare"]="1.15.4"
    ["timberio/vector"]="0.28.1"
    ["supabase/realtime"]="v2.37.2"
    ["supabase/storage-api"]="v1.24.6"
    ["darthsim/imgproxy"]="v3.28.0"
    ["supabase/postgres-meta"]="v0.89.3"
    ["supabase/edge-runtime"]="v1.68.0"
)

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get recommended version based on mode
get_recommended_version() {
    local image="$1"
    local current_tag="$2"
    
    if [[ "$OFFICIAL_MODE" == "true" ]]; then
        # Use official Supabase tested versions
        if [[ -n "${OFFICIAL_SUPABASE_VERSIONS[$image]}" ]]; then
            echo "${OFFICIAL_SUPABASE_VERSIONS[$image]}"
        else
            echo "$current_tag"
        fi
    else
        # Use conservative approach with API lookups
        get_latest_stable_tag "$image" "$current_tag" "false"
    fi
}

# Function to get latest stable tag while preserving flavor
get_latest_stable_tag() {
    local repo="$1"
    local current_tag="$2"
    local preserve_flavor="$3"
    
    # Skip if it's already 'latest'
    if [[ "$current_tag" == "latest" ]]; then
        echo "latest"
        return
    fi
    
    # Extract flavor from current tag
    local current_flavor=""
    if [[ "$current_tag" =~ -([a-zA-Z]+)$ ]]; then
        current_flavor="-${BASH_REMATCH[1]}"
    fi
    
    # Get available tags
    local tags_json
    tags_json=$(curl -s "https://registry.hub.docker.com/v2/repositories/$repo/tags/?page_size=100" 2>/dev/null)
    
    if [[ $? -ne 0 || -z "$tags_json" ]]; then
        echo "$current_tag"
        return
    fi
    
    # Filter for stable versions only (avoid rc, alpha, beta, develop)
    local stable_tags
    if [[ "$preserve_flavor" == "true" && -n "$current_flavor" ]]; then
        # Preserve the flavor
        stable_tags=$(echo "$tags_json" | jq -r '.results[] | select(.name | test("^[v]?[0-9].*'"$current_flavor"'$") and (test("rc|alpha|beta|develop") | not)) | .name' 2>/dev/null | head -5)
    else
        # Get stable tags without specific flavors
        stable_tags=$(echo "$tags_json" | jq -r '.results[] | select(.name | test("^[v]?[0-9]") and (test("rc|alpha|beta|develop|alpine|ubuntu|distroless") | not)) | .name' 2>/dev/null | head -5)
    fi
    
    if [[ -z "$stable_tags" ]]; then
        echo "$current_tag"
        return
    fi
    
    # Get the latest stable tag
    local latest_stable
    latest_stable=$(echo "$stable_tags" | head -1)
    
    echo "${latest_stable:-$current_tag}"
}

# Function to check if version is a major upgrade
is_major_upgrade() {
    local current="$1"
    local new="$2"
    
    # Extract major version numbers
    local current_major=$(echo "$current" | sed -n 's/^v\?\([0-9]\+\).*/\1/p')
    local new_major=$(echo "$new" | sed -n 's/^v\?\([0-9]\+\).*/\1/p')
    
    if [[ -n "$current_major" && -n "$new_major" && "$new_major" -gt "$current_major" ]]; then
        return 0  # true - it is a major upgrade
    fi
    return 1  # false - not a major upgrade
}

# Function to parse image line
parse_image_line() {
    local line="$1"
    local image_with_tag
    local image
    local tag
    
    # Extract image after 'image: '
    image_with_tag=$(echo "$line" | sed -n "s/.*image: ['\"]\\([^'\"]*\\)['\"].*/\\1/p")
    
    if [[ -z "$image_with_tag" ]]; then
        # Try without quotes
        image_with_tag=$(echo "$line" | sed -n 's/.*image: *\([^ ]*\).*/\1/p')
    fi
    
    if [[ "$image_with_tag" == *":"* ]]; then
        image="${image_with_tag%:*}"
        tag="${image_with_tag##*:}"
    else
        image="$image_with_tag"
        tag="latest"
    fi
    
    echo "$image:$tag"
}

# Function to update image tag safely
update_image_tag() {
    local file="$1"
    local old_image="$2"
    local new_image="$3"
    
    # Create temporary file for safer editing
    local temp_file=$(mktemp)
    
    # Use awk for reliable replacement
    awk -v old="$old_image" -v new="$new_image" '
    {
        if ($0 ~ /image:/) {
            gsub("image: ['\''\"]*" old "['\''\"]*", "image: '\''" new "'\''")
            gsub("image: *" old "$", "image: '\''" new "'\''")
        }
        print
    }' "$file" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$file"
}

# Check dependencies
command -v curl >/dev/null 2>&1 || { print_error "curl is required but not installed. Aborting."; exit 1; }
if [[ "$OFFICIAL_MODE" != "true" ]]; then
    command -v jq >/dev/null 2>&1 || { print_error "jq is required for API mode but not installed. Use --official mode or install jq. Aborting."; exit 1; }
fi

# Check if compose file exists
if [[ ! -f "$COMPOSE_FILE" ]]; then
    print_error "Docker compose file '$COMPOSE_FILE' not found!"
    echo "Usage: $0 [options] [compose-file]"
    exit 1
fi

print_status "Starting Supabase Docker Compose updater..."
if [[ "$OFFICIAL_MODE" == "true" ]]; then
    print_status "Mode: Official Supabase tested versions"
else
    print_status "Mode: Conservative API-based updates"
fi
print_status "Compose file: $COMPOSE_FILE"

# Create backup
cp "$COMPOSE_FILE" "$BACKUP_FILE"
print_success "Backup created: $BACKUP_FILE"

# Define image mappings and their update strategies
declare -A image_updates
declare -A major_upgrades_skipped

# Extract current images from compose file
while IFS= read -r line; do
    if [[ "$line" =~ image: ]]; then
        image_info=$(parse_image_line "$line")
        image="${image_info%:*}"
        current_tag="${image_info##*:}"
        
        # Skip if no image found
        [[ -z "$image" ]] && continue
        
        print_status "Checking $image:$current_tag..."
        
        case "$image" in
            "kong")
                if [[ "$OFFICIAL_MODE" == "true" ]]; then
                    latest_tag=$(get_recommended_version "$image" "$current_tag")
                    print_status "Using official Supabase version: $latest_tag"
                else
                    # Kong: Preserve exact version to avoid breaking changes
                    print_warning "Kong upgrades often have breaking changes - keeping current version"
                    latest_tag="$current_tag"
                fi
                ;;
            "supabase/postgres")
                if [[ "$OFFICIAL_MODE" == "true" ]]; then
                    latest_tag=$(get_recommended_version "$image" "$current_tag")
                    print_status "Using official Supabase Postgres version: $latest_tag"
                else
                    # Postgres: Major versions require migration - be very conservative
                    latest_tag=$(get_latest_stable_tag "supabase/postgres" "$current_tag" "false")
                    if is_major_upgrade "$current_tag" "$latest_tag"; then
                        print_warning "Postgres major version upgrade detected ($current_tag → $latest_tag) - skipping for safety"
                        major_upgrades_skipped["$image"]="$current_tag → $latest_tag (requires manual migration)"
                        latest_tag="$current_tag"
                    fi
                fi
                ;;
            "timberio/vector")
                if [[ "$OFFICIAL_MODE" == "true" ]]; then
                    latest_tag=$(get_recommended_version "$image" "$current_tag")
                    print_status "Using official Supabase version: $latest_tag"
                else
                    # Vector: Preserve Alpine flavor if present
                    if [[ "$current_tag" == *"-alpine" ]]; then
                        latest_tag=$(get_latest_stable_tag "timberio/vector" "$current_tag" "true")
                    else
                        latest_tag=$(get_latest_stable_tag "timberio/vector" "$current_tag" "false")
                    fi
                fi
                ;;
            "supabase/studio"|"supabase/gotrue"|"postgrest/postgrest"|"supabase/logflare"|"supabase/realtime"|"supabase/storage-api"|"darthsim/imgproxy"|"supabase/postgres-meta"|"supabase/edge-runtime")
                if [[ "$OFFICIAL_MODE" == "true" ]]; then
                    latest_tag=$(get_recommended_version "$image" "$current_tag")
                    print_status "Using official Supabase version: $latest_tag"
                else
                    # Supabase services: Get stable versions only
                    latest_tag=$(get_latest_stable_tag "$image" "$current_tag" "false")
                fi
                ;;
            "minio/minio"|"minio/mc")
                if [[ "$OFFICIAL_MODE" == "true" ]]; then
                    latest_tag=$(get_recommended_version "$image" "$current_tag")
                else
                    # MinIO: Usually safe to update
                    latest_tag=$(get_latest_stable_tag "$image" "$current_tag" "false")
                fi
                ;;
            "ghcr.io/coollabsio/coolify")
                # Coolify: Skip automatic updates - too risky
                print_warning "Coolify updates can be breaking - keeping current version"
                latest_tag="$current_tag"
                ;;
            *)
                print_warning "Unknown image: $image, skipping..."
                continue
                ;;
        esac
        
        # Store the update info
        old_image="$image:$current_tag"
        new_image="$image:$latest_tag"
        image_updates["$old_image"]="$new_image"
        
        if [[ "$current_tag" != "$latest_tag" ]]; then
            if [[ "$OFFICIAL_MODE" == "true" ]]; then
                print_status "Official update: $image $current_tag → $latest_tag"
            else
                print_status "Safe update available: $image $current_tag → $latest_tag"
            fi
        else
            print_status "Already up to date: $image:$current_tag"
        fi
    fi
done < <(grep -E "^\s*image:" "$COMPOSE_FILE")

echo ""
print_status "Applying updates to $COMPOSE_FILE..."

# Apply all updates
updated_count=0
for old_image in "${!image_updates[@]}"; do
    new_image="${image_updates[$old_image]}"
    if [[ "$old_image" != "$new_image" ]]; then
        update_image_tag "$COMPOSE_FILE" "$old_image" "$new_image"
        print_success "Updated: $old_image → $new_image"
        ((updated_count++))
    fi
done

echo ""
print_success "Update completed!"
print_status "Original file backed up as: $BACKUP_FILE"
print_status "Updated file: $COMPOSE_FILE"

# Show summary
echo ""
print_status "Summary of changes:"
if [[ $updated_count -eq 0 ]]; then
    if [[ "$OFFICIAL_MODE" == "true" ]]; then
        print_success "Already using official Supabase versions!"
    else
        print_success "No updates were applied - all images are already at safe versions!"
    fi
else
    for old_image in "${!image_updates[@]}"; do
        new_image="${image_updates[$old_image]}"
        if [[ "$old_image" != "$new_image" ]]; then
            echo "  ✅ $old_image → $new_image"
        fi
    done
    print_success "Successfully updated $updated_count image(s) safely"
fi

# Show skipped major upgrades (only in non-official mode)
if [[ "$OFFICIAL_MODE" != "true" && ${#major_upgrades_skipped[@]} -gt 0 ]]; then
    echo ""
    print_warning "Major upgrades skipped for safety:"
    for image in "${!major_upgrades_skipped[@]}"; do
        echo "  ⚠️  $image: ${major_upgrades_skipped[$image]}"
    done
    echo ""
    print_warning "Major upgrades require manual review and testing:"
    echo "  • Postgres major versions need migration planning"
    echo "  • Kong versions often have breaking API changes"
    echo "  • Always test in development environment first"
    echo "  • Consider using --official mode for tested combinations"
fi

if [[ $updated_count -gt 0 ]]; then
    echo ""
    if [[ "$OFFICIAL_MODE" == "true" ]]; then
        print_warning "Updated to official Supabase tested versions. Next steps:"
        echo "  1. These versions are tested together by Supabase team"
        echo "  2. Run 'docker-compose pull' to download new images"
        echo "  3. Run 'docker-compose up -d' to restart with new images"
        echo "  4. Monitor logs for any issues"
    else
        print_warning "Next steps:"
        echo "  1. Review the changes in $COMPOSE_FILE"
        echo "  2. Test in development environment first"
        echo "  3. Run 'docker-compose pull' to download new images"
        echo "  4. Run 'docker-compose up -d' to restart with new images"
        echo "  5. Monitor logs for any issues"
    fi
fi

# Ensure clean exit
exit 0