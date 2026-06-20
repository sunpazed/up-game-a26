# Define variables
SRC_DIR := src
BUILD_DIR := build
SOURCE := $(SRC_DIR)/up.asm
OUTPUT := $(BUILD_DIR)/up
DASM := dasm

# Define DASM flags
DASM_FLAGS := -f3 -o$(OUTPUT).a26 -I$(SRC_DIR) -l$(OUTPUT).lst -s$(OUTPUT).sym #-DDEBUG_KERNEL=1
# Default target
all: $(OUTPUT)

# Build target
$(OUTPUT): $(SOURCE)
	mkdir -p $(BUILD_DIR)
	$(DASM) $(SOURCE) $(DASM_FLAGS)

# Clean target
clean:
	rm -rf $(BUILD_DIR)/*.a26
	rm -rf $(BUILD_DIR)/*.sym
	rm -rf $(BUILD_DIR)/*.lst

# Phony targets
.PHONY: all clean