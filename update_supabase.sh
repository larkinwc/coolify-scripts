#!/bin/bash

# Supabase Docker Compose Image Updater
# This script updates Docker image tags in your Supabase compose file to the latest versions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
COMPOSE_FILE="${1:-docker-compose.yml}"
BACKUP_FILE="${COMPOSE_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

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

# Function to get latest tag from Docker Hub
get_latest_dockerhub_tag() {
    local repo="$1"
    local current_tag="$2"
    
    # Skip if it's already 'latest'
    if [[ "$current_tag" == "latest" ]]; then
        echo "latest"
        return
    fi
    
    print_status "Checking latest tag for $repo..."
    
    # Try to get the latest tag from Docker Hub API
    local latest_tag
    latest_tag=$(curl -s "https://registry.hub.docker.com/v2/repositories/$repo/tags/?page_size=100" | \
        jq -r '.results[] | select(.name | test("^[0-9]") or test("^v[0-9]")) | .name' | \
        head -1 2>/dev/null)
    
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        print_warning "Could not fetch latest tag for $repo, keeping current: $current_tag"
        echo "$current_tag"
    else
        echo "$latest_tag"
    fi
}

# Function to get latest tag from GitHub Container Registry
get_latest_ghcr_tag() {
    local repo="$1"
    local current_tag="$2"
    
    # Extract org/repo from ghcr.io/org/repo format
    local github_repo="${repo#ghcr.io/}"
    
    print_status "Checking latest release for GitHub repo: $github_repo..."
    
    # Try to get latest release from GitHub API
    local latest_tag
    latest_tag=$(curl -s "https://api.github.com/repos/$github_repo/releases/latest" | \
        jq -r '.tag_name // empty' 2>/dev/null)
    
    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        print_warning "Could not fetch latest release for $github_repo, keeping current: $current_tag"
        echo "$current_tag"
    else
        echo "$latest_tag"
    fi
}

# Function to extract image and tag from docker compose line
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

# Function to update image tag in the compose file
update_image_tag() {
    local file="$1"
    local old_image="$2"
    local new_image="$3"
    
    # Escape special characters for sed
    local escaped_old=$(echo "$old_image" | sed 's/[[\.*^$()+?{|]/\\&/g')
    local escaped_new=$(echo "$new_image" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Update the file
    sed -i.tmp "s|image: ['\"]\\?${escaped_old}['\"]\\?|image: '${escaped_new}'|g" "$file"
    rm -f "${file}.tmp"
}

# Check dependencies
command -v curl >/dev/null 2>&1 || { print_error "curl is required but not installed. Aborting."; exit 1; }
command -v jq >/dev/null 2>&1 || { print_error "jq is required but not installed. Aborting."; exit 1; }

# Check if compose file exists
if [[ ! -f "$COMPOSE_FILE" ]]; then
    print_error "Docker compose file '$COMPOSE_FILE' not found!"
    echo "Usage: $0 [compose-file]"
    exit 1
fi

print_status "Starting Supabase Docker Compose updater..."
print_status "Compose file: $COMPOSE_FILE"

# Create backup
cp "$COMPOSE_FILE" "$BACKUP_FILE"
print_success "Backup created: $BACKUP_FILE"

# Define image mappings and their registries
declare -A image_updates

# Extract current images from compose file
while IFS= read -r line; do
    if [[ "$line" =~ image:.*['\"]?([^'\"]+)['\"]? ]]; then
        image_info=$(parse_image_line "$line")
        image="${image_info%:*}"
        current_tag="${image_info##*:}"
        
        case "$image" in
            "kong")
                latest_tag=$(get_latest_dockerhub_tag "library/kong" "$current_tag")
                ;;
            "supabase/studio")
                latest_tag=$(get_latest_dockerhub_tag "supabase/studio" "$current_tag")
                ;;
            "supabase/postgres")
                latest_tag=$(get_latest_dockerhub_tag "supabase/postgres" "$current_tag")
                ;;
            "supabase/logflare")
                latest_tag=$(get_latest_dockerhub_tag "supabase/logflare" "$current_tag")
                ;;
            "timberio/vector")
                latest_tag=$(get_latest_dockerhub_tag "timberio/vector" "$current_tag")
                ;;
            "postgrest/postgrest")
                latest_tag=$(get_latest_dockerhub_tag "postgrest/postgrest" "$current_tag")
                ;;
            "supabase/gotrue")
                latest_tag=$(get_latest_dockerhub_tag "supabase/gotrue" "$current_tag")
                ;;
            "supabase/realtime")
                latest_tag=$(get_latest_dockerhub_tag "supabase/realtime" "$current_tag")
                ;;
            "minio/minio"|"minio/mc")
                latest_tag=$(get_latest_dockerhub_tag "$image" "$current_tag")
                ;;
            "supabase/storage-api")
                latest_tag=$(get_latest_dockerhub_tag "supabase/storage-api" "$current_tag")
                ;;
            "darthsim/imgproxy")
                latest_tag=$(get_latest_dockerhub_tag "darthsim/imgproxy" "$current_tag")
                ;;
            "supabase/postgres-meta")
                latest_tag=$(get_latest_dockerhub_tag "supabase/postgres-meta" "$current_tag")
                ;;
            "supabase/edge-runtime")
                latest_tag=$(get_latest_dockerhub_tag "supabase/edge-runtime" "$current_tag")
                ;;
            "ghcr.io/coollabsio/coolify")
                latest_tag=$(get_latest_ghcr_tag "coollabsio/coolify" "$current_tag")
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
            print_status "Update available: $image $current_tag → $latest_tag"
        else
            print_status "Already up to date: $image:$current_tag"
        fi
    fi
done < <(grep -E "^\s*image:" "$COMPOSE_FILE")

echo ""
print_status "Applying updates to $COMPOSE_FILE..."

# Apply all updates
for old_image in "${!image_updates[@]}"; do
    new_image="${image_updates[$old_image]}"
    if [[ "$old_image" != "$new_image" ]]; then
        update_image_tag "$COMPOSE_FILE" "$old_image" "$new_image"
        print_success "Updated: $old_image → $new_image"
    fi
done

echo ""
print_success "Update completed!"
print_status "Original file backed up as: $BACKUP_FILE"
print_status "Updated file: $COMPOSE_FILE"

# Show summary
echo ""
print_status "Summary of changes:"
updated_count=0
for old_image in "${!image_updates[@]}"; do
    new_image="${image_updates[$old_image]}"
    if [[ "$old_image" != "$new_image" ]]; then
        echo "  $old_image → $new_image"
        ((updated_count++))
    fi
done

if [[ $updated_count -eq 0 ]]; then
    print_success "No updates were needed - all images are already up to date!"
else
    print_success "Successfully updated $updated_count image(s)"
    echo ""
    print_warning "Remember to:"
    echo "  1. Review the changes in $COMPOSE_FILE"
    echo "  2. Test the updated configuration in a development environment"
    echo "  3. Run 'docker-compose pull' to download new images"
    echo "  4. Run 'docker-compose up -d' to restart with new images"
fi