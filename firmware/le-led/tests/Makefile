CXX ?= c++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O1 -g
# OpenSSL supplies AES on the host. On macOS with Homebrew:
#   make OPENSSL=$(brew --prefix openssl)
ifdef OPENSSL
CXXFLAGS += -I$(OPENSSL)/include
LDFLAGS += -L$(OPENSSL)/lib
endif
# OpenSSL 3 marks the low-level AES calls deprecated; they are fine here.
CXXFLAGS += -Wno-deprecated-declarations

all: run

test_le_proto: test_le_proto.cpp ../le_proto.cpp ../le_proto.h
	$(CXX) $(CXXFLAGS) -o $@ test_le_proto.cpp ../le_proto.cpp $(LDFLAGS) -lcrypto

run: test_le_proto
	./test_le_proto
	python3 cross_check.py

clean:
	rm -f test_le_proto

.PHONY: all run clean
