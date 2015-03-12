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

#import "RLMArray_Private.hpp"
#import "RLMObject_Private.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMProperty_Private.h"
#import "RLMQueryUtil.hpp"
#import "RLMRealm_Private.hpp"
#import "RLMSchema.h"
#import "RLMUtil.hpp"

#import <objc/runtime.h>

//
// RLMArray implementation
//
@implementation RLMArrayLinkView {
    realm::LinkViewRef _backingLinkView;
    RLMRealm *_realm;
    RLMObjectSchema *_objectSchema;
}

+ (RLMArrayLinkView *)arrayWithObjectClassName:(NSString *)objectClassName
                                          view:(realm::LinkViewRef)view
                                  parentObject:(RLMObjectBase *)object
                                           key:(NSString *)key {
    RLMArrayLinkView *ar = [[RLMArrayLinkView alloc] initWithObjectClassName:objectClassName parentObject:object key:key];
    ar->_backingLinkView = view;
    ar->_realm = object->_realm;
    ar->_objectSchema = ar->_realm.schema[objectClassName];
    return ar;
}

//
// validation helpers
//
static inline void RLMLinkViewArrayValidateAttached(__unsafe_unretained RLMArrayLinkView *const ar) {
    if (!ar->_backingLinkView->is_attached()) {
        @throw RLMException(@"RLMArray is no longer valid");
    }
    RLMCheckThread(ar->_realm);
}
static inline void RLMLinkViewArrayValidateInWriteTransaction(__unsafe_unretained RLMArrayLinkView *const ar) {
    // first verify attached
    RLMLinkViewArrayValidateAttached(ar);

    if (!ar->_realm->_inWriteTransaction) {
        @throw RLMException(@"Can't mutate a persisted array outside of a write transaction.");
    }
}
static inline void RLMValidateObjectClass(__unsafe_unretained RLMObjectBase *const obj, __unsafe_unretained NSString *const expected) {
    if (!obj) {
        @throw RLMException(@"Object is `nil`", @{@"expected class" : expected});
    }

    NSString *objectClassName = obj->_objectSchema.className;
    if (![objectClassName isEqualToString:expected]) {
        @throw RLMException(@"Object type is incorrect.", @{@"expected class" : expected, @"actual class" : objectClassName});
    }
}

static void changeArray(__unsafe_unretained RLMArrayLinkView *const ar, NSKeyValueChange kind, NSUInteger index, dispatch_block_t f) {
    if (!ar->_parentObject->_objectSchema->_observers) {
        f();
        return;
    }

    NSIndexSet *is = [NSIndexSet indexSetWithIndex:index];
    RLMWillChange(ar->_parentObject, ar->_key, kind, is);
    f();
    RLMDidChange(ar->_parentObject, ar->_key, kind, is);
}

static void changeArray(__unsafe_unretained RLMArrayLinkView *const ar, NSKeyValueChange kind, NSIndexSet *index, dispatch_block_t f) {
    if (!ar->_parentObject->_objectSchema->_observers) {
        f();
        return;
    }

    RLMWillChange(ar->_parentObject, ar->_key, kind, index);
    f();
    RLMDidChange(ar->_parentObject, ar->_key, kind, index);
}

//
// public method implementations
//
- (NSUInteger)count {
    RLMLinkViewArrayValidateAttached(self);
    return _backingLinkView->size();
}

- (BOOL)isInvalidated {
    return !_backingLinkView->is_attached();
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(__unsafe_unretained id [])buffer count:(NSUInteger)len {
    RLMLinkViewArrayValidateAttached(self);

    __autoreleasing RLMCArrayHolder *items;
    if (state->state == 0) {
        items = [[RLMCArrayHolder alloc] initWithSize:len];
        state->extra[0] = (long)items;
        state->extra[1] = _backingLinkView->size();
    }
    else {
        // FIXME: mutationsPtr should be pointing to a value updated by core
        // whenever the linkview is changed rather than doing this check
        if (state->extra[1] != self.count) {
            @throw RLMException(@"Collection was mutated while being enumerated.");
        }
        items = (__bridge id)(void *)state->extra[0];
        [items resize:len];
    }

    NSUInteger batchCount = 0, index = state->state, count = state->extra[1];

    Class accessorClass = _objectSchema.accessorClass;
    realm::Table &table = *_objectSchema.table;
    while (index < count && batchCount < len) {
        RLMObject *accessor = [[accessorClass alloc] initWithRealm:_realm schema:_objectSchema];
        accessor->_row = table[_backingLinkView->get(index++).get_index()];
        items->array[batchCount] = accessor;
        buffer[batchCount] = accessor;
        batchCount++;
    }

    for (NSUInteger i = batchCount; i < len; ++i) {
        items->array[i] = nil;
    }

    state->itemsPtr = buffer;
    state->state = index;
    state->mutationsPtr = state->extra+1;

    return batchCount;
}

- (id)objectAtIndex:(NSUInteger)index {
    RLMLinkViewArrayValidateAttached(self);

    if (index >= _backingLinkView->size()) {
        @throw RLMException(@"Index is out of bounds.", @{@"index": @(index)});
    }
    return RLMCreateObjectAccessor(_realm, _objectSchema, _backingLinkView->get(index).get_index());
}

- (void)insertObject:(RLMObject *)object atIndex:(NSUInteger)index {
    RLMLinkViewArrayValidateInWriteTransaction(self);
    RLMValidateObjectClass(object, self.objectClassName);

    if (index > _backingLinkView->size()) {
        @throw RLMException(@"Trying to insert object at invalid index");
    }
    if (object->_realm != self.realm) {
        [self.realm addObject:object];
    }

    changeArray(self, NSKeyValueChangeInsertion, index, ^{
        _backingLinkView->insert(index, object->_row.get_index());
    });
}

- (void)removeObjectAtIndex:(NSUInteger)index {
    RLMLinkViewArrayValidateInWriteTransaction(self);

    if (index >= _backingLinkView->size()) {
        @throw RLMException(@"Trying to remove object at invalid index");
    }

    changeArray(self, NSKeyValueChangeRemoval, index, ^{
        _backingLinkView->remove(index);
    });
}

- (void)removeAllObjects {
    RLMLinkViewArrayValidateInWriteTransaction(self);

    changeArray(self, NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _backingLinkView->size())], ^{
        _backingLinkView->clear();
    });
}

- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(RLMObject *)object {
    RLMLinkViewArrayValidateInWriteTransaction(self);
    RLMValidateObjectClass(object, self.objectClassName);

    if (index >= _backingLinkView->size()) {
        @throw RLMException(@"Trying to replace object at invalid index");
    }
    if (object->_realm != self.realm) {
        [self.realm addObject:object];
    }

    changeArray(self, NSKeyValueChangeReplacement, index, ^{
        _backingLinkView->set(index, object->_row.get_index());
    });
}

- (NSUInteger)indexOfObject:(RLMObject *)object {
    // check attached for table and object
    RLMLinkViewArrayValidateAttached(self);

    if (object->_realm && !object->_row.is_attached()) {
        @throw RLMException(@"RLMObject is no longer valid");
    }

    // check that object types align
    if (![_objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException([NSString stringWithFormat:@"Object of type (%@) does not match RLMArray type (%@)",
                             object->_objectSchema.className, _objectClassName]);
    }

    // if different tables then no match
    if (object->_row.get_table() != &_backingLinkView->get_target_table()) {
        return NSNotFound;
    }

    // call find on backing array
    size_t object_ndx = object->_row.get_index();
    return RLMConvertNotFound(_backingLinkView->find(object_ndx));
}

- (id)valueForKey:(NSString *)key {
    RLMLinkViewArrayValidateAttached(self);
    const size_t size = _backingLinkView->size();
    return RLMCollectionValueForKey(key, _realm, _objectSchema, size, ^size_t(size_t index) {
        return _backingLinkView->get(index).get_index();
    });
}

- (void)setValue:(id)value forKey:(NSString *)key {
    RLMLinkViewArrayValidateInWriteTransaction(self);
    const size_t size = _backingLinkView->size();
    RLMCollectionSetValueForKey(value, key, _realm, _objectSchema, size, ^size_t(size_t index) {
        return _backingLinkView->get(index).get_index();
    });
}

- (void)deleteObjectsFromRealm {
    RLMLinkViewArrayValidateInWriteTransaction(self);

    // delete all target rows from the realm
    changeArray(self, NSKeyValueChangeRemoval, [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _backingLinkView->size())], ^{
        _backingLinkView->clear();
    });
}

- (RLMResults *)sortedResultsUsingDescriptors:(NSArray *)properties {
    RLMLinkViewArrayValidateAttached(self);

    std::vector<size_t> columns;
    std::vector<bool> order;
    RLMGetColumnIndices(_realm.schema[_objectClassName], properties, columns, order);

    realm::TableView const &tv = _backingLinkView->get_sorted_view(move(columns), move(order));
    auto query = std::make_unique<realm::Query>(_backingLinkView->get_target_table().where(_backingLinkView));
    return [RLMResults resultsWithObjectClassName:self.objectClassName
                                                 query:move(query)
                                                  view:tv
                                                 realm:_realm];

}

- (RLMResults *)objectsWithPredicate:(NSPredicate *)predicate {
    RLMLinkViewArrayValidateAttached(self);

    realm::Query query = _backingLinkView->get_target_table().where(_backingLinkView);
    RLMUpdateQueryWithPredicate(&query, predicate, _realm.schema, _realm.schema[self.objectClassName]);
    return [RLMResults resultsWithObjectClassName:self.objectClassName
                                            query:std::make_unique<realm::Query>(query)
                                            realm:_realm];
}

- (NSUInteger)indexOfObjectWithPredicate:(NSPredicate *)predicate {
    RLMLinkViewArrayValidateAttached(self);

    realm::Query query = _backingLinkView->get_target_table().where(_backingLinkView);
    RLMUpdateQueryWithPredicate(&query, predicate, _realm.schema, _realm.schema[self.objectClassName]);
    return RLMConvertNotFound(query.find());
}

@end
