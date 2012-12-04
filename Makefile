SDK_PATH=$(shell xcode-select -print-path)
IOS_CC = $(SDK_PATH)/Platforms/iPhoneOS.platform/Developer/usr/bin/gcc

all: fruitstrap

demo.app: demo Info.plist
	mkdir -p demo.app
	cp demo demo.app/
	cp Info.plist ResourceRules.plist demo.app/
	codesign -f -s "iPhone Developer" --entitlements Entitlements.plist demo.app

demo: demo.c
	$(IOS_CC) -arch armv7 -isysroot $(SDK_PATH)/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS5.0.sdk -framework CoreFoundation -o demo demo.c

fruitstrap: fruitstrap.m
	clang -Wall -Wextra -g -o fruitstrap -fobjc-arc -framework CoreFoundation -framework MobileDevice -framework Foundation -F/System/Library/PrivateFrameworks fruitstrap.m

install: all
	./fruitstrap install --bundle=demo.app

debug: all
	./fruitstrap install --bundle=demo.app --debug

clean:
	rm -rf *.app demo fruitstrap
