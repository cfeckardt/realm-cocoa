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

#import "RLMObject_Private.hpp"

#import "RLMAccessor.h"
#import "RLMArray.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMProperty_Private.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMSwiftSupport.h"
#import "RLMUtil.hpp"

@implementation RLMObservable {
    RLMRealm *_realm;
    RLMObjectSchema *_objectSchema;
}
- (instancetype)initWithRow:(realm::Row const&)row realm:(RLMRealm *)realm schema:(RLMObjectSchema *)objectSchema {
    self = [super init];
    if (self) {
        _row = row;
        _realm = realm;
        _objectSchema = objectSchema;
    }
    return self;
}

- (id)valueForKey:(NSString *)key {
    RLMObject *obj = [[RLMObject alloc] initWithRealm:_realm schema:_objectSchema];
    obj->_row = _row;
    return RLMDynamicGet(obj, key);
}
@end

const NSUInteger RLMDescriptionMaxDepth = 5;

@implementation RLMObjectBase {
    @public
    NSMutableArray *_observers;
}

// standalone init
- (instancetype)init {
    if (RLMSchema.sharedSchema) {
        RLMObjectSchema *objectSchema = [self.class sharedSchema];
        self = [self initWithRealm:nil schema:objectSchema];

        // set default values
        if (!objectSchema.isSwiftClass) {
            NSDictionary *dict = RLMDefaultValuesForObjectSchema(objectSchema);
            for (NSString *key in dict) {
                [self setValue:dict[key] forKey:key];
            }
        }

        // set standalone accessor class
        object_setClass(self, objectSchema.standaloneClass);
    }
    else {
        // if schema not initialized
        // this is only used for introspection
        self = [super init];
    }

    return self;
}

- (instancetype)initWithObject:(id)value schema:(RLMSchema *)schema {
    self = [self init];
    if (NSArray *array = RLMDynamicCast<NSArray>(value)) {
        // validate and populate
        array = RLMValidatedArrayForObjectSchema(array, _objectSchema, schema);
        NSArray *properties = _objectSchema.properties;
        for (NSUInteger i = 0; i < array.count; i++) {
            [self setValue:array[i] forKeyPath:[properties[i] name]];
        }
    }
    else {
        // assume our object is an NSDictionary or a an object with kvc properties
        NSDictionary *dict = RLMValidatedDictionaryForObjectSchema(value, _objectSchema, schema);
        for (NSString *name in dict) {
            id val = dict[name];
            // strip out NSNull before passing values to standalone setters
            if (val == NSNull.null) {
                val = nil;
            }
            [self setValue:val forKeyPath:name];
        }
    }

    return self;
}

- (instancetype)initWithRealm:(__unsafe_unretained RLMRealm *const)realm
                       schema:(__unsafe_unretained RLMObjectSchema *const)schema {
    self = [super init];
    if (self) {
        _realm = realm;
        _objectSchema = schema;
    }
    return self;
}

// overridden at runtime per-class for performance
+ (NSString *)className {
    NSString *className = NSStringFromClass(self);
    if ([RLMSwiftSupport isSwiftClassName:className]) {
        className = [RLMSwiftSupport demangleClassName:className];
    }
    return className;
}

// overridden at runtime per-class for performance
+ (RLMObjectSchema *)sharedSchema {
    return RLMSchema.sharedSchema[self.className];
}

- (NSString *)description
{
    if (self.isInvalidated) {
        return @"[invalid object]";
    }

    return [self descriptionWithMaxDepth:RLMDescriptionMaxDepth];
}

- (NSString *)descriptionWithMaxDepth:(NSUInteger)depth {
    if (depth == 0) {
        return @"<Maximum depth exceeded>";
    }

    NSString *baseClassName = _objectSchema.className;
    NSMutableString *mString = [NSMutableString stringWithFormat:@"%@ {\n", baseClassName];

    for (RLMProperty *property in _objectSchema.properties) {
        id object = RLMObjectBaseObjectForKeyedSubscript(self, property.name);
        NSString *sub;
        if ([object respondsToSelector:@selector(descriptionWithMaxDepth:)]) {
            sub = [object descriptionWithMaxDepth:depth - 1];
        }
        else if (property.type == RLMPropertyTypeData) {
            static NSUInteger maxPrintedDataLength = 24;
            NSData *data = object;
            NSUInteger length = data.length;
            if (length > maxPrintedDataLength) {
                data = [NSData dataWithBytes:data.bytes length:maxPrintedDataLength];
            }
            NSString *dataDescription = [data description];
            sub = [NSString stringWithFormat:@"<%@ — %lu total bytes>", [dataDescription substringWithRange:NSMakeRange(1, dataDescription.length - 2)], (unsigned long)length];
        }
        else {
            sub = [object description];
        }
        [mString appendFormat:@"\t%@ = %@;\n", property.name, [sub stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"]];
    }
    [mString appendString:@"}"];

    return [NSString stringWithString:mString];
}

- (BOOL)isInvalidated {
    // if not standalone and our accessor has been detached, we have been deleted
    return self.class == _objectSchema.accessorClass && !_row.is_attached();
}

- (BOOL)isDeletedFromRealm {
    return self.isInvalidated;
}

- (BOOL)isEqual:(id)object {
    if (RLMObjectBase *other = RLMDynamicCast<RLMObjectBase>(object)) {
        if (_objectSchema.primaryKeyProperty) {
            return RLMObjectBaseAreEqual(self, other);
        }
    }
    return [super isEqual:object];
}

- (NSUInteger)hash {
    if (_objectSchema.primaryKeyProperty) {
        id primaryProperty = [self valueForKey:_objectSchema.primaryKeyProperty.name];

        // modify the hash of our primary key value to avoid potential (although unlikely) collisions
        return [primaryProperty hash] ^ 1;
    }
    else {
        return [super hash];
    }
}

- (id)mutableArrayValueForKey:(NSString *)key {
    id obj = [self valueForKey:key];
    if ([obj isKindOfClass:[RLMArray class]]) {
        return obj;
    }
    return [super mutableArrayValueForKey:key];
}

static NSString *keyFromPath(NSString *keyPath) {
    NSUInteger sep = [keyPath rangeOfString:@"."].location;
    return sep == NSNotFound ? keyPath : [keyPath substringToIndex:sep];
}

static RLMObservable *getObservable(RLMObjectSchema *objectSchema, RLMRealm *realm, realm::Row const& row) {
    for (RLMObservable *o in objectSchema->_observers) {
        if (o->_row.get_index() == row.get_index()) {
            return o;
        }
    }

    RLMObservable *observable = [[RLMObservable alloc] initWithRow:row realm:realm schema:objectSchema];
    if (!objectSchema->_observers) {
        objectSchema->_observers = [NSMutableArray new];
    }
    [objectSchema->_observers addObject:observable];
    return observable;
}

- (void)addObserver:(id)observer
         forKeyPath:(NSString *)keyPath
            options:(NSKeyValueObservingOptions)options
            context:(void *)context {
    NSString *key = keyFromPath(keyPath);
    if (!_objectSchema[key]) {
        [super addObserver:observer forKeyPath:keyPath options:options context:context];
        return;
    }

    RLMObservable *observable = getObservable(_objectSchema, _realm, _row);
    [observable addObserver:observer forKeyPath:keyPath options:options context:context];
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath {
    if (_objectSchema[keyFromPath(keyPath)]) {
        [getObservable(_objectSchema, _realm, _row) removeObserver:observer forKeyPath:keyPath];
    }
    else {
        [super removeObserver:observer forKeyPath:keyPath];
    }
}

- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)keyPath context:(void *)context {
    if (_objectSchema[keyFromPath(keyPath)]) {
        [getObservable(_objectSchema, _realm, _row) removeObserver:observer forKeyPath:keyPath context:context];
    }
    else {
        [super removeObserver:observer forKeyPath:keyPath context:context];
    }
}

@end

void RLMWillChange(RLMObjectBase *obj, NSString *key) {
    [getObservable(obj->_objectSchema, obj->_realm, obj->_row) willChangeValueForKey:key];
}

void RLMDidChange(RLMObjectBase *obj, NSString *key) {
    [getObservable(obj->_objectSchema, obj->_realm, obj->_row) didChangeValueForKey:key];
}

void RLMWillChange(RLMObjectBase *obj, NSString *key, NSKeyValueChange kind, NSIndexSet *indices) {
    [getObservable(obj->_objectSchema, obj->_realm, obj->_row) willChange:kind valuesAtIndexes:indices forKey:key];
}

void RLMDidChange(RLMObjectBase *obj, NSString *key, NSKeyValueChange kind, NSIndexSet *indices) {
    [getObservable(obj->_objectSchema, obj->_realm, obj->_row) didChange:kind valuesAtIndexes:indices forKey:key];
}

@implementation RLMObservationInfo
@end

void RLMObjectBaseSetRealm(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMRealm *realm) {
    if (object) {
        object->_realm = realm;
    }
}

RLMRealm *RLMObjectBaseRealm(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_realm : nil;
}

void RLMObjectBaseSetObjectSchema(__unsafe_unretained RLMObjectBase *object, __unsafe_unretained RLMObjectSchema *objectSchema) {
    if (object) {
        object->_objectSchema = objectSchema;
    }
}

RLMObjectSchema *RLMObjectBaseObjectSchema(__unsafe_unretained RLMObjectBase *object) {
    return object ? object->_objectSchema : nil;
}

NSArray *RLMObjectBaseLinkingObjectsOfClass(RLMObjectBase *object, NSString *className, NSString *property) {
    if (!object) {
        return nil;
    }

    if (!object->_realm) {
        @throw RLMException(@"Linking object only available for objects in a Realm.");
    }
    RLMCheckThread(object->_realm);

    if (!object->_row.is_attached()) {
        @throw RLMException(@"Object has been deleted or invalidated and is no longer valid.");
    }

    RLMObjectSchema *schema = object->_realm.schema[className];
    RLMProperty *prop = schema[property];
    if (!prop) {
        @throw RLMException([NSString stringWithFormat:@"Invalid property '%@'", property]);
    }

    if (![prop.objectClassName isEqualToString:object->_objectSchema.className]) {
        @throw RLMException([NSString stringWithFormat:@"Property '%@' of '%@' expected to be an RLMObject or RLMArray property pointing to type '%@'", property, className, object->_objectSchema.className]);
    }

    Table *table = schema.table;
    if (!table) {
        return @[];
    }

    size_t col = prop.column;
    NSUInteger count = object->_row.get_backlink_count(*table, col);
    NSMutableArray *links = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        [links addObject:RLMCreateObjectAccessor(object->_realm, schema, object->_row.get_backlink(*table, col, i))];
    }
    return [links copy];
}

id RLMObjectBaseObjectForKeyedSubscript(RLMObjectBase *object, NSString *key) {
    if (!object) {
        return nil;
    }

    if (object->_realm) {
        return RLMDynamicGet(object, key);
    }
    else {
        return [object valueForKey:key];
    }
}

void RLMObjectBaseSetObjectForKeyedSubscript(RLMObjectBase *object, NSString *key, id obj) {
    if (!object) {
        return;
    }

    if (object->_realm) {
        RLMDynamicValidatedSet(object, key, obj);
    }
    else {
        [object setValue:obj forKey:key];
    }
}


BOOL RLMObjectBaseAreEqual(RLMObjectBase *o1, RLMObjectBase *o2) {
    // if not the correct types throw
    if ((o1 && ![o1 isKindOfClass:RLMObjectBase.class]) || (o2 && ![o2 isKindOfClass:RLMObjectBase.class])) {
        @throw RLMException(@"Can only compare objects of class RLMObjectBase");
    }
    // if identical object (or both are nil)
    if (o1 == o2) {
        return YES;
    }
    // if one is nil
    if (o1 == nil || o2 == nil) {
        return NO;
    }
    // if not in realm or differing realms
    if (o1->_realm == nil || o1->_realm != o2->_realm) {
        return NO;
    }
    // if either are detached
    if (!o1->_row.is_attached() || !o2->_row.is_attached()) {
        return NO;
    }
    // if table and index are the same
    return o1->_row.get_table() == o2->_row.get_table() &&
    o1->_row.get_index() == o2->_row.get_index();
}


Class RLMObjectUtilClass(BOOL isSwift) {
    static Class objectUtilObjc = [RLMObjectUtil class];
    static Class objectUtilSwift = NSClassFromString(@"RealmSwift.ObjectUtil");
    return isSwift && objectUtilSwift ? objectUtilSwift : objectUtilObjc;
}

@implementation RLMObjectUtil

+ (NSString *)primaryKeyForClass:(Class)cls {
    return [cls primaryKey];
}

+ (NSArray *)ignoredPropertiesForClass:(Class)cls {
    return [cls ignoredProperties];
}

+ (NSArray *)indexedPropertiesForClass:(Class)cls {
    return [cls indexedProperties];
}

+ (NSArray *)getGenericListPropertyNames:(__unused id)obj {
    return nil;
}

+ (void)initializeListProperty:(__unused RLMObjectBase *)object property:(__unused RLMProperty *)property array:(__unused RLMArray *)array {
}

@end

void RLMOverrideStandaloneMethods(Class cls) {
    struct methodInfo {
        SEL sel;
        IMP imp;
        const char *type;
    };

    auto get = [](SEL sel) {
        Method m = class_getInstanceMethod(NSObject.class, sel);
        IMP imp = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        return methodInfo{sel, imp, type};
    };

    auto make = [](SEL sel, auto&& func) {
        Method m = class_getInstanceMethod(NSObject.class, sel);
        IMP superImp = method_getImplementation(m);
        const char *type = method_getTypeEncoding(m);
        IMP imp = imp_implementationWithBlock(func(sel, superImp));
        return methodInfo{sel, imp, type};
    };

    static const methodInfo methods[] = {
        get(@selector(willChangeValueForKey:)),
        get(@selector(willChange:valuesAtIndexes:forKey:)),
        get(@selector(didChangeValueForKey:)),
        get(@selector(didChange:valuesAtIndexes:forKey:)),

        make(@selector(addObserver:forKeyPath:options:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, NSKeyValueObservingOptions, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, NSKeyValueObservingOptions options, void *context) {
                if (!self->_observers)
                    self->_observers = [NSMutableArray new];

                RLMObservationInfo *info = [RLMObservationInfo new];
                info.observer = observer;
                info.options = options;
                info.context = context;
                info.key = keyPath;
                [self->_observers addObject:info];
                superFn(self, sel, observer, keyPath, options, context);
            };
        }),

        make(@selector(removeObserver:forKeyPath:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath) {
                for (RLMObservationInfo *info in self->_observers) {
                    if (info.observer == observer && [info.key isEqualToString:keyPath]) {
                        [self->_observers removeObject:info];
                        break;
                    }
                }
                superFn(self, sel, observer, keyPath);
            };
        }),

        make(@selector(removeObserver:forKeyPath:context:), [](SEL sel, IMP superImp) {
            auto superFn = (void (*)(id, SEL, id, NSString *, void *))superImp;
            return ^(RLMObjectBase *self, id observer, NSString *keyPath, void *context) {
                for (RLMObservationInfo *info in self->_observers) {
                    if (info.observer == observer && info.context == context && [info.key isEqualToString:keyPath]) {
                        [self->_observers removeObject:info];
                        break;
                    }
                }
                superFn(self, sel, observer, keyPath, context);
            };
        })
    };

    for (auto const& m : methods)
        class_addMethod(cls, m.sel, m.imp, m.type);
}

void RLMConvertStandaloneToAccessor(RLMObjectBase *obj, Class accessorClass) {
    NSMutableArray *observers = obj->_observers;
    obj->_observers = nil;

    for (RLMObservationInfo *info in observers) {
        [obj removeObserver:info.observer forKeyPath:info.key context:info.context];
    }

    object_setClass(obj, accessorClass);

    for (RLMObservationInfo *info in observers) {
        [obj addObserver:info.observer
              forKeyPath:info.key
                 options:info.options & ~NSKeyValueObservingOptionInitial
                 context:info.context];
    }
}