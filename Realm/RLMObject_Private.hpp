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

#import "RLMObject_Private.h"

#import <realm/link_view.hpp> // required by row.hpp
#import <realm/row.hpp>

@interface RLMObservable : NSObject {
    @public
    realm::Row _row;
}
@property (nonatomic) void *observationInfo;
@end

// RLMObject accessor and read/write realm
@interface RLMObjectBase () {
    @public
    realm::Row _row;
}

@end

void RLMOverrideStandaloneMethods(Class cls);
void RLMConvertStandaloneToAccessor(RLMObjectBase *obj, Class accessorClass);

void RLMWillChange(RLMObjectBase *obj, NSString *key);
void RLMDidChange(RLMObjectBase *obj, NSString *key);

void RLMWillChange(RLMObjectBase *obj, NSString *key, NSKeyValueChange kind, NSIndexSet *indices);
void RLMDidChange(RLMObjectBase *obj, NSString *key, NSKeyValueChange kind, NSIndexSet *indices);
