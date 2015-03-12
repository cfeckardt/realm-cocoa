////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMArray_Private.h"
#import "RLMResults.h"

#import <memory>

namespace realm {
    class LinkView;
    class Query;
    class TableView;

    namespace util {
        template<typename T> class bind_ptr;
    }
    typedef util::bind_ptr<LinkView> LinkViewRef;
}

@class RLMObjectSchema;
@class RLMObjectBase;

@interface RLMArray () {
  @protected
    NSString *_objectClassName;
  @public
    RLMObjectBase *_parentObject;
    NSString *_key;
}

// initializer
- (instancetype)initWithObjectClassName:(NSString *)objectClassName
                           parentObject:(RLMObjectBase *)object
                                    key:(NSString *)key;

// deletes all objects in the RLMArray from their containing realms
- (void)deleteObjectsFromRealm;

@end


//
// LinkView backed RLMArray subclass
//
@interface RLMArrayLinkView : RLMArray
+ (RLMArrayLinkView *)arrayWithObjectClassName:(NSString *)objectClassName
                                          view:(realm::LinkViewRef)view
                                  parentObject:(RLMObjectBase *)object
                                           key:(NSString *)key;
@end


//
// RLMResults private methods
//
@interface RLMResults ()
+ (instancetype)resultsWithObjectClassName:(NSString *)objectClassName
                                     query:(std::unique_ptr<realm::Query>)query
                                     realm:(RLMRealm *)realm;

+ (instancetype)resultsWithObjectClassName:(NSString *)objectClassName
                                     query:(std::unique_ptr<realm::Query>)query
                                      view:(realm::TableView)view
                                     realm:(RLMRealm *)realm;
- (void)deleteObjectsFromRealm;
@end

//
// RLMResults subclass used when a TableView can't be created - this is used
// for readonly realms where we can't create an underlying table class for a
// type, and we need to return a functional RLMResults instance which is always empty.
//
@interface RLMEmptyResults : RLMResults
+ (instancetype)emptyResultsWithObjectClassName:(NSString *)objectClassName
                                          realm:(RLMRealm *)realm;
@end

// RLMResults backed by a realm::Table directly rather than using a TableView
@interface RLMTableResults : RLMResults
+ (RLMResults *)tableResultsWithObjectSchema:(RLMObjectSchema *)objectSchema realm:(RLMRealm *)realm;
@end

//
// A simple holder for a C array of ids to enable autoreleasing the array without
// the runtime overhead of a NSMutableArray
//
@interface RLMCArrayHolder : NSObject {
@public
    std::unique_ptr<id[]> array;
    NSUInteger size;
}

- (instancetype)initWithSize:(NSUInteger)size;

// Reallocate the array if it is not already the given size
- (void)resize:(NSUInteger)size;
@end
